#!/usr/bin/env bash
# Rebuilds docs/TeslesSeasons-Manual.pdf from the HTML sources in this directory.
#
# The manual is written as one HTML file per part so that a section can be edited
# without scrolling through forty pages of markup. build.sh concatenates them in
# order and renders with WeasyPrint, which is what gives the print CSS - running
# heads, repeated table headers, page breaks that avoid orphaned headings.
#
#   pip install weasyprint
#   docs/manual/build.sh
set -euo pipefail
cd "$(dirname "$0")"
cat 01.html 02.html 03.html 04.html 05.html 06.html 07.html 08.html 09.html 10.html > manual.html
python3 -c "import weasyprint; weasyprint.HTML('manual.html').write_pdf('../TeslesSeasons-Manual.pdf')"
rm -f manual.html
echo "wrote docs/TeslesSeasons-Manual.pdf"
