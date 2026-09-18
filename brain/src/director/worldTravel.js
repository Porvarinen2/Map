'use strict';
const {createRng}=require('../core/prng');
const {centroid}=require('../groups/autoGroup');
function planGroupTravel(group,{seed='world',timeBucket=0,radiusCm=35000}={}){const c=centroid(group);const rng=createRng(`${seed}|${group.groupId}|${timeBucket}`);const angle=rng()*Math.PI*2;const radius=radiusCm*(.35+rng()*.65);return{x:c.x+Math.cos(angle)*radius,y:c.y+Math.sin(angle)*radius,z:c.z};}
module.exports={planGroupTravel};
