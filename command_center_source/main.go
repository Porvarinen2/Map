package main

import (
	"embed"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

//go:embed web/* assets/*
var content embed.FS

type Server struct {
	root       string
	mu         sync.Mutex
	cmd        *exec.Cmd
	realityCmd *exec.Cmd
	liveCmd    *exec.Cmd
}

type StartReq struct {
	Minutes       float64 `json:"minutes"`
	Envs          int     `json:"envs"`
	ShowcaseEvery int64   `json:"showcase_every"`
	Visual        bool    `json:"visual"`
	VisualQuality string  `json:"visual_quality"`
}

type LiveReq struct {
	Mode     string `json:"mode"`
	Lock     string `json:"lock"`
	Attempts int    `json:"attempts"`
}

type VisualEvalReq struct {
	Episodes int `json:"episodes"`
	Envs     int `json:"envs"`
}

type WipeReq struct {
	Mode    string `json:"mode"`
	Confirm string `json:"confirm"`
}

type RealityReq struct {
	Lock string `json:"lock"`
}

func exeRoot() string {
	p, err := os.Executable()
	if err != nil {
		d, _ := os.Getwd()
		return d
	}
	p, _ = filepath.Abs(p)
	return filepath.Dir(p)
}

func atomicWrite(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0644); err != nil {
		return err
	}
	_ = os.Remove(path)
	return os.Rename(tmp, path)
}

func jsonReply(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(v)
}

func (s *Server) configPath() string { return filepath.Join(s.root, "freelearn_config.json") }
func (s *Server) dataPath(parts ...string) string {
	p := append([]string{s.root, "data"}, parts...)
	return filepath.Join(p...)
}

func pathSize(path string) (int64, int, error) {
	var total int64
	files := 0
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		return 0, 0, nil
	}
	if err != nil {
		return 0, 0, err
	}
	if !info.IsDir() {
		return info.Size(), 1, nil
	}
	err = filepath.Walk(path, func(p string, i os.FileInfo, e error) error {
		if e != nil {
			return e
		}
		if !i.IsDir() {
			total += i.Size()
			files++
		}
		return nil
	})
	return total, files, err
}

func removeContents(dir string) (int64, int, error) {
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		_ = os.MkdirAll(dir, 0755)
		return 0, 0, nil
	}
	if err != nil {
		return 0, 0, err
	}
	var bytes int64
	files := 0
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		b, n, er := pathSize(p)
		if er != nil {
			return bytes, files, er
		}
		if er := os.RemoveAll(p); er != nil {
			return bytes, files, er
		}
		bytes += b
		files += n
	}
	return bytes, files, nil
}

func removeGlob(pattern string) (int64, int, error) {
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return 0, 0, err
	}
	var bytes int64
	files := 0
	for _, p := range matches {
		b, n, er := pathSize(p)
		if er != nil {
			return bytes, files, er
		}
		if er := os.RemoveAll(p); er != nil {
			return bytes, files, er
		}
		bytes += b
		files += n
	}
	return bytes, files, nil
}

func (s *Server) simulationDataStats() (int64, int) {
	var bytes int64
	files := 0
	pats := []string{
		filepath.Join(s.root, "data", "freelearn_*"),
		filepath.Join(s.root, "data", "showcase_request.flag"),
		filepath.Join(s.root, "checkpoints", "freelearn_*"),
	}
	for _, pat := range pats {
		matches, _ := filepath.Glob(pat)
		for _, p := range matches {
			b, n, _ := pathSize(p)
			bytes += b
			files += n
		}
	}
	return bytes, files
}

func (s *Server) allDataStats() (int64, int) {
	var bytes int64
	files := 0
	for _, p := range []string{filepath.Join(s.root, "data"), filepath.Join(s.root, "checkpoints")} {
		b, n, _ := pathSize(p)
		bytes += b
		files += n
	}
	return bytes, files
}

func (s *Server) realityDir(parts ...string) string {
	p := append([]string{s.root, "data", "real_bridge"}, parts...)
	return filepath.Join(p...)
}

func (s *Server) realityRunningLocked() bool {
	return s.realityCmd != nil && s.realityCmd.Process != nil && s.realityCmd.ProcessState == nil
}

func pythonCommand(root string, args ...string) (*exec.Cmd, error) {
	if p, err := exec.LookPath("py.exe"); err == nil {
		a := append([]string{"-3"}, args...)
		cmd := exec.Command(p, a...)
		cmd.Dir = root
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		return cmd, nil
	}
	if p, err := exec.LookPath("python.exe"); err == nil {
		cmd := exec.Command(p, args...)
		cmd.Dir = root
		cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
		return cmd, nil
	}
	return nil, fmt.Errorf("Python not found (py.exe/python.exe)")
}

func (s *Server) apiRealityStatus(w http.ResponseWriter, r *http.Request) {
	m := map[string]any{"version": "0.18.0", "recorder": "offline", "samples": 0, "episodes": 0, "overall_match": 0.0}
	if b, err := os.ReadFile(s.realityDir("status.json")); err == nil {
		_ = json.Unmarshal(b, &m)
	}
	if b, err := os.ReadFile(s.realityDir("fit_profile.json")); err == nil {
		var fit map[string]any
		if json.Unmarshal(b, &fit) == nil {
			m["fit"] = fit
			if v, ok := fit["overall_match"]; ok {
				m["overall_match"] = v
			}
		}
	}
	s.mu.Lock()
	m["running"] = s.realityRunningLocked()
	s.mu.Unlock()
	jsonReply(w, m)
}

func (s *Server) apiRealityStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	var q RealityReq
	_ = json.NewDecoder(r.Body).Decode(&q)
	lock := strings.TrimSpace(q.Lock)
	valid := map[string]bool{"Auto": true, "Rusted": true, "Basic": true, "Medium": true, "Enforced": true}
	if !valid[lock] {
		lock = "Auto"
	}
	if err := os.MkdirAll(s.realityDir(), 0755); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	_ = os.Remove(s.realityDir("stop.flag"))
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.realityRunningLocked() {
		http.Error(w, "REAL capture already running", 409)
		return
	}
	cmd, err := pythonCommand(s.root, filepath.Join(s.root, "real_sim_bridge.py"), "record", "--lock", lock)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	logf, err := os.OpenFile(s.realityDir("recorder.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Start(); err != nil {
		logf.Close()
		http.Error(w, err.Error(), 500)
		return
	}
	s.realityCmd = cmd
	_ = os.WriteFile(s.realityDir("launcher.pid"), []byte(strconv.Itoa(cmd.Process.Pid)), 0644)
	go func(c *exec.Cmd, f *os.File) {
		_ = c.Wait()
		_ = f.Close()
		s.mu.Lock()
		if s.realityCmd == c {
			s.realityCmd = nil
		}
		s.mu.Unlock()
	}(cmd, logf)
	jsonReply(w, map[string]any{"ok": true, "pid": cmd.Process.Pid, "lock": lock})
}

func (s *Server) apiRealityStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	_ = os.MkdirAll(s.realityDir(), 0755)
	_ = os.WriteFile(s.realityDir("stop.flag"), []byte(time.Now().Format(time.RFC3339Nano)), 0644)
	s.mu.Lock()
	cmd := s.realityCmd
	s.mu.Unlock()
	go func() {
		time.Sleep(1200 * time.Millisecond)
		if cmd != nil && cmd.Process != nil && cmd.ProcessState == nil {
			_ = exec.Command("taskkill", "/PID", strconv.Itoa(cmd.Process.Pid), "/T", "/F").Run()
		}
	}()
	jsonReply(w, map[string]any{"ok": true, "stop_requested": true})
}

func (s *Server) apiRealityFit(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	s.mu.Lock()
	running := s.realityRunningLocked()
	s.mu.Unlock()
	if running {
		http.Error(w, "Stop REAL capture before fitting so the dataset is stable.", 409)
		return
	}
	cmd, err := pythonCommand(s.root, filepath.Join(s.root, "real_sim_bridge.py"), "fit")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		http.Error(w, string(out)+"\n"+err.Error(), 500)
		return
	}
	var fit map[string]any
	b, er := os.ReadFile(s.realityDir("fit_profile.json"))
	if er == nil {
		_ = json.Unmarshal(b, &fit)
	}
	jsonReply(w, map[string]any{"ok": true, "output": string(out), "fit": fit})
}

func (s *Server) apiRealityReplay(w http.ResponseWriter, r *http.Request) {
	b, err := os.ReadFile(s.realityDir("latest_replay.json"))
	if err != nil {
		jsonReply(w, map[string]any{"episode_id": ""})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(b)
}

func (s *Server) apiRealityLog(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(tailFile(s.realityDir("recorder.log"), 120)))
}

func (s *Server) apiConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		b, err := os.ReadFile(s.configPath())
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(b)
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	b, err := io.ReadAll(io.LimitReader(r.Body, 2<<20))
	if err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		http.Error(w, "invalid json: "+err.Error(), 400)
		return
	}
	pretty, _ := json.MarshalIndent(v, "", "  ")
	if err := atomicWrite(s.configPath(), append(pretty, '\n')); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	jsonReply(w, map[string]any{"ok": true, "hot_reload": true})
}

func (s *Server) runningLocked() bool {
	return s.cmd != nil && s.cmd.Process != nil && s.cmd.ProcessState == nil
}

func (s *Server) apiStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	var q StartReq
	if err := json.NewDecoder(r.Body).Decode(&q); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	if q.Envs < 64 {
		if q.Visual {
			q.Envs = 96
		} else {
			q.Envs = 8192
		}
	}
	if q.ShowcaseEvery < 1000 {
		q.ShowcaseEvery = 1000000
	}
	if q.Minutes < 0 {
		q.Minutes = 0
	}
	// Persist launch controls into config first.
	b, err := os.ReadFile(s.configPath())
	if err == nil {
		var c map[string]any
		if json.Unmarshal(b, &c) == nil {
			if tr, ok := c["training"].(map[string]any); ok {
				tr["envs"] = q.Envs
				tr["showcase_every_attempts"] = q.ShowcaseEvery
			}
			if out, e := json.MarshalIndent(c, "", "  "); e == nil {
				_ = atomicWrite(s.configPath(), append(out, '\n'))
			}
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.runningLocked() {
		http.Error(w, "trainer already running", 409)
		return
	}
	if err := os.MkdirAll(s.dataPath(), 0755); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	logf, err := os.OpenFile(s.dataPath("freelearn_console.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	trainer := filepath.Join(s.root, "freelearn_trainer.py")
	args := []string{trainer, "--minutes", fmt.Sprintf("%.4f", q.Minutes), "--envs", strconv.Itoa(q.Envs), "--showcase-every", strconv.FormatInt(q.ShowcaseEvery, 10)}
	if q.Visual {
		quality := q.VisualQuality
		if quality != "live" {
			quality = "fast"
		}
		args = append(args, "--visual", "--visual-quality", quality)
	}
	var cmd *exec.Cmd
	if p, err := exec.LookPath("py.exe"); err == nil {
		cmd = exec.Command(p, append([]string{"-3"}, args...)...)
	} else if p, err := exec.LookPath("python.exe"); err == nil {
		cmd = exec.Command(p, args...)
	} else {
		logf.Close()
		http.Error(w, "Python not found (py.exe/python.exe)", 500)
		return
	}
	cmd.Dir = s.root
	cmd.Stdout = logf
	cmd.Stderr = logf
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	if err := cmd.Start(); err != nil {
		logf.Close()
		http.Error(w, err.Error(), 500)
		return
	}
	s.cmd = cmd
	_ = os.WriteFile(s.dataPath("freelearn_trainer.pid"), []byte(strconv.Itoa(cmd.Process.Pid)), 0644)
	go func(c *exec.Cmd, f *os.File) {
		_ = c.Wait()
		_ = f.Close()
		s.mu.Lock()
		if s.cmd == c {
			s.cmd = nil
		}
		s.mu.Unlock()
	}(cmd, logf)
	jsonReply(w, map[string]any{"ok": true, "pid": cmd.Process.Pid})
}

func (s *Server) apiStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	s.mu.Lock()
	cmd := s.cmd
	s.mu.Unlock()
	killed := false
	if cmd != nil && cmd.Process != nil {
		_ = exec.Command("taskkill", "/PID", strconv.Itoa(cmd.Process.Pid), "/T", "/F").Run()
		killed = true
	}
	if !killed {
		if b, err := os.ReadFile(s.dataPath("freelearn_trainer.pid")); err == nil {
			if pid, er := strconv.Atoi(strings.TrimSpace(string(b))); er == nil {
				_ = exec.Command("taskkill", "/PID", strconv.Itoa(pid), "/T", "/F").Run()
				killed = true
			}
		}
	}
	jsonReply(w, map[string]any{"ok": true, "kill_requested": killed})
}

func (s *Server) apiStatus(w http.ResponseWriter, r *http.Request) {
	m := map[string]any{"status": "offline", "running": false}
	if b, err := os.ReadFile(s.dataPath("freelearn_telemetry.json")); err == nil {
		_ = json.Unmarshal(b, &m)
	}
	s.mu.Lock()
	m["running"] = s.runningLocked()
	s.mu.Unlock()
	jsonReply(w, m)
}
func (s *Server) apiShowcase(w http.ResponseWriter, r *http.Request) {
	b, err := os.ReadFile(s.dataPath("freelearn_showcase.json"))
	if err != nil {
		jsonReply(w, map[string]any{"showcase": -1})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write(b)
}
func (s *Server) apiShowcaseRequest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	_ = os.MkdirAll(s.dataPath(), 0755)
	err := os.WriteFile(s.dataPath("showcase_request.flag"), []byte(time.Now().Format(time.RFC3339)), 0644)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	jsonReply(w, map[string]any{"ok": true})
}

func (s *Server) apiWipeStatus(w http.ResponseWriter, r *http.Request) {
	simB, simN := s.simulationDataStats()
	allB, allN := s.allDataStats()
	jsonReply(w, map[string]any{"simulation_bytes": simB, "simulation_files": simN, "all_bytes": allB, "all_files": allN})
}

func (s *Server) apiWipe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	var q WipeReq
	if err := json.NewDecoder(r.Body).Decode(&q); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	s.mu.Lock()
	running := s.runningLocked()
	realityRunning := s.realityRunningLocked()
	s.mu.Unlock()
	if running || realityRunning {
		http.Error(w, "Stop training and REAL capture before wiping data. This prevents deleting files while Python is writing them.", 409)
		return
	}
	mode := strings.ToLower(strings.TrimSpace(q.Mode))
	var bytes int64
	files := 0
	var err error
	switch mode {
	case "simulation":
		if strings.TrimSpace(q.Confirm) != "WIPE SIM" {
			http.Error(w, "confirmation mismatch", 400)
			return
		}
		pats := []string{
			filepath.Join(s.root, "data", "freelearn_*"),
			filepath.Join(s.root, "data", "showcase_request.flag"),
			filepath.Join(s.root, "checkpoints", "freelearn_*"),
		}
		for _, pat := range pats {
			var b int64
			var n int
			b, n, err = removeGlob(pat)
			bytes += b
			files += n
			if err != nil {
				http.Error(w, err.Error(), 500)
				return
			}
		}
		_ = os.MkdirAll(filepath.Join(s.root, "data"), 0755)
		_ = os.MkdirAll(filepath.Join(s.root, "checkpoints"), 0755)
	case "all":
		if strings.TrimSpace(q.Confirm) != "WIPE ALL" {
			http.Error(w, "confirmation mismatch", 400)
			return
		}
		var b int64
		var n int
		b, n, err = removeContents(filepath.Join(s.root, "data"))
		bytes += b
		files += n
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		b, n, err = removeContents(filepath.Join(s.root, "checkpoints"))
		bytes += b
		files += n
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
	default:
		http.Error(w, "unknown wipe mode", 400)
		return
	}
	jsonReply(w, map[string]any{"ok": true, "mode": mode, "removed_bytes": bytes, "removed_files": files})
}

func tailFile(path string, maxLines int) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return "Trainer log will appear here after START TRAINING.\n"
	}
	lines := strings.Split(string(b), "\n")
	if len(lines) > maxLines {
		lines = lines[len(lines)-maxLines:]
	}
	return strings.Join(lines, "\n")
}
func (s *Server) apiLog(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(tailFile(s.dataPath("freelearn_console.log"), 260)))
}

func (s *Server) apiProgress(w http.ResponseWriter, r *http.Request) {
	f, err := os.Open(s.dataPath("freelearn_progress.csv"))
	if err != nil {
		jsonReply(w, []any{})
		return
	}
	defer f.Close()
	rd := csv.NewReader(f)
	rows, err := rd.ReadAll()
	if err != nil || len(rows) < 2 {
		jsonReply(w, []any{})
		return
	}
	hdr := rows[0]
	start := 1
	if len(rows)-start > 250 {
		start = len(rows) - 250
	}
	out := make([]map[string]any, 0, len(rows)-start)
	for _, row := range rows[start:] {
		m := map[string]any{}
		for i, k := range hdr {
			if i >= len(row) {
				continue
			}
			v := row[i]
			switch k {
			case "attempts", "steps":
				n, _ := strconv.ParseInt(v, 10, 64)
				m[k] = n
			case "Rusted", "Basic", "Medium", "Enforced", "steps_per_sec", "loss", "kl", "entropy", "best_mean":
				x, _ := strconv.ParseFloat(v, 64)
				m[k] = x
			default:
				m[k] = v
			}
		}
		out = append(out, m)
	}
	jsonReply(w, out)
}

func (s *Server) liveDir(parts ...string) string {
	p := append([]string{s.root, "data", "live"}, parts...)
	return filepath.Join(p...)
}

func (s *Server) liveRunningLocked() bool {
	return s.liveCmd != nil && s.liveCmd.Process != nil && s.liveCmd.ProcessState == nil
}

// apiVision reports the sensor model the simulator trains against plus the
// calibration the live reader will use.
func (s *Server) apiVision(w http.ResponseWriter, r *http.Request) {
	out := map[string]any{}
	if b, err := os.ReadFile(s.configPath()); err == nil {
		var c map[string]any
		if json.Unmarshal(b, &c) == nil {
			out["vision"] = c["vision"]
		}
	}
	if b, err := os.ReadFile(s.dataPath("live", "turn_calibration.json")); err == nil {
		var t map[string]any
		if json.Unmarshal(b, &t) == nil {
			out["turn_calibration"] = t
		}
	}
	if b, err := os.ReadFile(s.dataPath("freelearn_telemetry.json")); err == nil {
		var t map[string]any
		if json.Unmarshal(b, &t) == nil {
			out["vision_attempts"] = t["vision_attempts"]
			out["vision_scale"] = t["vision_scale"]
			out["visual_sim"] = t["visual_sim"]
		}
	}
	if b, err := os.ReadFile(s.dataPath("live", "visual_eval.json")); err == nil {
		var t map[string]any
		if json.Unmarshal(b, &t) == nil {
			out["last_eval"] = t
		}
	}
	jsonReply(w, out)
}

func (s *Server) apiVisualCalibrate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	s.mu.Lock()
	running := s.runningLocked()
	s.mu.Unlock()
	if running {
		http.Error(w, "Stop training first: calibration rewrites freelearn_config.json and the trainer reads the vision model at startup.", 409)
		return
	}
	cmd, err := pythonCommand(s.root, filepath.Join(s.root, "freelearn_visual_sim.py"), "--calibrate")
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		http.Error(w, string(out)+"\n"+err.Error(), 500)
		return
	}
	jsonReply(w, map[string]any{"ok": true, "output": string(out)})
}

func (s *Server) apiVisualEval(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	var q VisualEvalReq
	_ = json.NewDecoder(r.Body).Decode(&q)
	if q.Episodes < 8 {
		q.Episodes = 96
	}
	if q.Envs < 4 {
		q.Envs = 48
	}
	cmd, err := pythonCommand(s.root, filepath.Join(s.root, "freelearn_visual_sim.py"), "--eval",
		"--episodes", strconv.Itoa(q.Episodes), "--envs", strconv.Itoa(q.Envs))
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		http.Error(w, string(out)+"\n"+err.Error(), 500)
		return
	}
	jsonReply(w, map[string]any{"ok": true, "output": string(out)})
}

func (s *Server) apiLiveStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	var q LiveReq
	_ = json.NewDecoder(r.Body).Decode(&q)
	valid := map[string]bool{"Auto": true, "Rusted": true, "Basic": true, "Medium": true, "Enforced": true}
	if !valid[q.Lock] {
		q.Lock = "Auto"
	}
	args := []string{filepath.Join(s.root, "freelearn_live.py"), "--lock", q.Lock}
	switch q.Mode {
	case "observe":
		args = append(args, "--observe")
	case "calibrate":
		args = append(args, "--calibrate")
	default:
		q.Mode = "play"
		if q.Attempts > 0 {
			args = append(args, "--attempts", strconv.Itoa(q.Attempts))
		}
		args = append(args, "--trace")
	}
	if err := os.MkdirAll(s.liveDir(), 0755); err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.liveRunningLocked() {
		http.Error(w, "live agent already running", 409)
		return
	}
	cmd, err := pythonCommand(s.root, args...)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	logf, err := os.OpenFile(s.liveDir("live_console.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	cmd.Stdout, cmd.Stderr = logf, logf
	if err := cmd.Start(); err != nil {
		logf.Close()
		http.Error(w, err.Error(), 500)
		return
	}
	s.liveCmd = cmd
	go func(c *exec.Cmd, f *os.File) {
		_ = c.Wait()
		_ = f.Close()
		s.mu.Lock()
		if s.liveCmd == c {
			s.liveCmd = nil
		}
		s.mu.Unlock()
	}(cmd, logf)
	jsonReply(w, map[string]any{"ok": true, "pid": cmd.Process.Pid, "mode": q.Mode, "lock": q.Lock})
}

func (s *Server) apiLiveStop(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method", 405)
		return
	}
	s.mu.Lock()
	cmd := s.liveCmd
	s.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = exec.Command("taskkill", "/PID", strconv.Itoa(cmd.Process.Pid), "/T", "/F").Run()
	}
	jsonReply(w, map[string]any{"ok": true})
}

func (s *Server) apiLiveStatus(w http.ResponseWriter, r *http.Request) {
	m := map[string]any{"attempts": 0, "successes": 0}
	if b, err := os.ReadFile(s.liveDir("live_status.json")); err == nil {
		_ = json.Unmarshal(b, &m)
	}
	s.mu.Lock()
	m["running"] = s.liveRunningLocked()
	s.mu.Unlock()
	m["log"] = tailFile(s.liveDir("live_console.log"), 40)
	jsonReply(w, m)
}

func (s *Server) handler() http.Handler {
	mux := http.NewServeMux()
	webfs, _ := fs.Sub(content, "web")
	mux.Handle("/", http.FileServer(http.FS(webfs)))
	mux.HandleFunc("/asset/", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/asset/")
		if strings.Contains(name, "..") {
			http.NotFound(w, r)
			return
		}
		b, err := content.ReadFile("assets/" + name)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		if strings.HasSuffix(strings.ToLower(name), ".png") {
			w.Header().Set("Content-Type", "image/png")
		}
		_, _ = w.Write(b)
	})
	mux.HandleFunc("/api/config", s.apiConfig)
	mux.HandleFunc("/api/start", s.apiStart)
	mux.HandleFunc("/api/stop", s.apiStop)
	mux.HandleFunc("/api/status", s.apiStatus)
	mux.HandleFunc("/api/showcase", s.apiShowcase)
	mux.HandleFunc("/api/showcase/request", s.apiShowcaseRequest)
	mux.HandleFunc("/api/log", s.apiLog)
	mux.HandleFunc("/api/progress", s.apiProgress)
	mux.HandleFunc("/api/wipe/status", s.apiWipeStatus)
	mux.HandleFunc("/api/wipe", s.apiWipe)
	mux.HandleFunc("/api/reality/status", s.apiRealityStatus)
	mux.HandleFunc("/api/reality/start", s.apiRealityStart)
	mux.HandleFunc("/api/reality/stop", s.apiRealityStop)
	mux.HandleFunc("/api/reality/fit", s.apiRealityFit)
	mux.HandleFunc("/api/reality/replay", s.apiRealityReplay)
	mux.HandleFunc("/api/reality/log", s.apiRealityLog)
	mux.HandleFunc("/api/vision", s.apiVision)
	mux.HandleFunc("/api/visual/calibrate", s.apiVisualCalibrate)
	mux.HandleFunc("/api/visual/eval", s.apiVisualEval)
	mux.HandleFunc("/api/live/start", s.apiLiveStart)
	mux.HandleFunc("/api/live/stop", s.apiLiveStop)
	mux.HandleFunc("/api/live/status", s.apiLiveStatus)
	return mux
}

func findPort() (net.Listener, int, error) {
	for p := 8765; p < 8795; p++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p))
		if err == nil {
			return ln, p, nil
		}
	}
	return nil, 0, fmt.Errorf("no free localhost port")
}
func main() {
	root := exeRoot()
	_ = os.MkdirAll(filepath.Join(root, "data"), 0755)
	s := &Server{root: root}
	ln, port, err := findPort()
	if err != nil {
		panic(err)
	}
	url := fmt.Sprintf("http://127.0.0.1:%d/", port)
	go func() {
		time.Sleep(350 * time.Millisecond)
		_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	}()
	fmt.Printf("Lockpick AI Command Center: %s\n", url)
	if err := http.Serve(ln, s.handler()); err != nil {
		panic(err)
	}
}
