// Vorschau-GIF: zwei Bilder aus einer Bildersuche in die Ablage, auf einem anderen Schreibtisch
// auf eine Folie, ein Archiv in den Papierkorb und alles wieder zurück (echter Kreislauf).
const C=(x)=>Math.max(0,Math.min(1,x)), lerp=(a,b,t)=>a+(b-a)*t;
// Sanftes An- und Abbremsen wie bei einer echten Handbewegung
const io=(t)=>0.5-0.5*Math.cos(Math.PI*t);
const out=(t)=>1-Math.pow(1-t,3);
const back=(t)=>{const c1=1.2,c3=c1+1;return 1+c3*Math.pow(t-1,3)+c1*Math.pow(t-1,2)};
const seg=(t,a,b)=>C((t-a)/(b-a));
const $=(id)=>document.getElementById(id);
function path(t,keys){
  if(t<=keys[0][0])return keys[0].slice(1,3);
  for(let i=1;i<keys.length;i++){if(t<=keys[i][0]){const[a,x0,y0]=keys[i-1],[b,x1,y1,arc=0]=keys[i];const u=io(C((t-a)/(b-a)));
    const bow=Math.sin(u*Math.PI)*arc;return[lerp(x0,x1,u),lerp(y0,y1,u)-bow]}}
  return keys[keys.length-1].slice(1,3)}

// Die Ablage zählt den Zeiger noch 18 pt neben ihrer Form als „darüber“ (EdgeController)
const S=window.SLOTS, BODY_LEFT=506+280*374/880-18;
const LAKE=[40+203+95.5,120+61], DUSK=[40+2*203+95.5,120+134+61], PH1=[118+60+30+105,24+38+98+96+79], PH2=[118+60+260+105,24+38+98+96+79];
const inRect=(x,y,cx,cy,w,h)=>Math.abs(x-cx)<=w/2&&Math.abs(y-cy)<=h/2;
const DUR=19.3;
const P=[[0,430,470],[0.6,430,470],[1.25,LAKE[0],LAKE[1],10],[1.35,LAKE[0],LAKE[1]],[2.5,858,290,40],[2.85,858,290],
  [3.5,DUSK[0],DUSK[1],25],[3.6,DUSK[0],DUSK[1]],[4.8,858,290,40],[5.1,858,290],[5.7,520,430,10],[6.75,520,430],
  [7.25,872,285,20],[7.7,872,285],[8.2,S.r1c2[0],S.r1c2[1]+2,15],[8.35,S.r1c2[0],S.r1c2[1]+2],[9.5,PH1[0],PH1[1],30],[9.75,PH1[0],PH1[1]],
  [10.3,872,285,25],[10.75,872,285],[11.2,S.r1c1[0],S.r1c1[1]+2,15],[11.35,S.r1c1[0],S.r1c1[1]+2],[12.4,PH2[0],PH2[1],25],[12.65,PH2[0],PH2[1]],
  [13.1,872,285,15],[13.55,872,285],[14.05,S.r1c2[0],S.r1c2[1]+2,15],[14.25,S.r1c2[0],S.r1c2[1]+2],[15.05,S.trash[0],S.trash[1],15],[16.15,S.trash[0],S.trash[1]],
  [16.9,450,420,15],[18.3,450,420],[19.0,430,470,15],[19.3,430,470]];
// Wann der Zeiger die offene Ablage verlässt
function leaveAfter(t0){for(let t=t0;t<DUR;t+=1/120){if(path(t,P)[0]<BODY_LEFT)return t}return DUR}
const L_A=leaveAfter(2.5), L_B=leaveAfter(4.8), L_1=leaveAfter(8.4), L_2=leaveAfter(11.4), L_C=leaveAfter(15.3);

function shelfImage(t){
  if(t<2.5) return 'h0d';
  if(t<4.45) return 'h1';
  if(t<4.8) return 'h1d';
  if(t<8.35) return 'h2';
  if(t<10) return 'h2l';
  if(t<11.35) return 'h3';
  if(t<13) return 'h3d';
  if(t<14.25) return 'h4';
  if(t<14.75) return 'h4a';
  if(t<15.1) return 'h4t';
  if(t<15.8) return 'h5';
  return 'h4';
}
function openness(t){
  const win=[[2.15,L_A+0.3],[4.45,L_B+0.3],[7.6,L_1],[10.65,L_2],[13.45,L_C+0.3]];
  for(const [a,b] of win){
    if(t>=a&&t<b) return back(seg(t,a,a+0.28));
    if(t>=b&&t<b+0.25) return 1-io(seg(t,b,b+0.22));
  }
  return 0;
}
function strip(t){
  const w=[[1.4,2.15],[3.7,4.45],[7.3,7.6],[10.35,10.65],[13.15,13.45]];
  for(const [a,b] of w) if(t>=a&&t<b+0.15) return seg(t,a,a+0.12)*(1-seg(t,b,b+0.15));
  return 0;
}
function keys(t){
  const k=[[15.55,16.1,['⌘','Z']]];
  for(const [a,b,v] of k){ if(t>=a-0.12&&t<b+0.12) return [v, seg(t,a-0.12,a)*(1-seg(t,b,b+0.12))]; }
  return [[],0];
}
// Ruhiger ablaufen lassen: etwas langsamer, nach wichtigen Schritten kurz innehalten
const SLOW=1.25;
// Pausen nur, wenn der Zeiger ohnehin ruht, damit nichts mitten in der Bewegung stehen bleibt
// Am Rand: Der Streifen steht einen Moment, bevor die Ablage aufgeht (wie mit der Verzögerung der App)
const HOLDS=[[2.8,0.5],[5.05,0.7],[6.7,0.4],[7.5,0.4],[10.55,0.4],[13.35,0.4],[9.7,0.6],[12.6,0.7],[15.35,0.6],[16.12,0.5],[17.9,0.3]].sort((a,b)=>a[0]-b[0]);
function sceneTime(real){
  let r=real,last=0;
  for(const [at,hold] of HOLDS){
    const span=(at-last)*SLOW;
    if(r<span) return last+r/SLOW;
    r-=span; if(r<hold) return at; r-=hold; last=at;
  }
  return Math.min(DUR,last+r/SLOW);
}
const REAL=DUR*SLOW+HOLDS.reduce((a,h)=>a+h[1],0);
let lastKeys='';
window.render=function(real){
  real=((real%REAL)+REAL)%REAL;
  const t=sceneTime(real);
  const [px,py]=path(t,P);
  const pt=$('pointer'); pt.style.left=(px-2)+'px'; pt.style.top=(py-2)+'px';

  // Schreibtische: Wischen zur Präsentation und am Ende zurück
  let sw=0; if(t>=6.0&&t<17.25) sw=io(seg(t,6.0,6.65)); if(t>=17.25) sw=1-io(seg(t,17.25,17.9));
  $('sp1').style.transform=`translateX(${-900*sw}px)`; $('sp2').style.transform=`translateX(${900*(1-sw)}px)`;
  const inPresent=sw>=0.5;
  $('app').textContent=inPresent?'Present':'Browser'; $('m4').textContent=inPresent?'Insert':'History';

  // Gezogenes
  const g=$('ghost'); let html='', go=0, gx=px, gy=py;
  const web=(src,a,b,target)=>{ // Bild aus dem Browser: halbdurchsichtig am Zeiger, fliegt beim Loslassen in die Ablage
    // Wie in macOS: Beim Ablegen verschwindet das Ziehbild einfach, die Ablage zeigt die neue Kachel
    go=.72*(1-seg(t,b,b+0.06));
    html=`<div style="position:absolute;left:-60px;top:-39px;width:120px;height:78px;border-radius:6px;background:url(${src}) center/cover"></div>`;
  };
  const tile=(src,a,b,target,label)=>{ // Kachel aus der Ablage auf die Folie
    go=.85*(1-seg(t,b,b+0.06));
    html=`<div style="position:absolute;left:-27px;top:-20px;width:54px;height:40px;border-radius:3px;background:url(${src}) center/cover;box-shadow:0 3px 8px rgba(0,0,0,.45)"></div>`+
      (true?`<div style="position:absolute;left:-60px;top:24px;width:120px;text-align:center"><span style="font-size:10.5px;font-weight:600;color:#fff;background:#2f6ff5;padding:1px 5px;border-radius:4px;white-space:nowrap">${label}</span></div>`:'');
  };
  if(t>=1.35&&t<2.65) web('GIF3_mountain-lake.png',1.35,2.5,S.r1c1);
  else if(t>=3.6&&t<4.95) web('GIF3_alpine-dusk.png',3.6,4.8,S.r1c1);
  else if(t>=8.4&&t<9.65) tile('GIF3_mountain-lake.png',8.4,9.5,PH1,'mountain-lake.jpg');
  else if(t>=11.4&&t<12.55) tile('GIF3_alpine-dusk.png',11.4,12.4,PH2,'alpine-dusk.jpg');
  else if(t>=14.3&&t<15.2){
    let u=0; if(t>=15.1) u=out(seg(t,15.1,15.2)); go=.85*(1-u);
    html=`<img src="GIF3_archive_icon.png" style="position:absolute;left:-27px;top:-27px;width:54px;height:54px;transform:scale(${1-u*.6})">`+
      (u<0.01?`<div style="position:absolute;left:-40px;top:30px;width:80px;text-align:center"><span style="font-size:10.5px;font-weight:600;color:#fff;background:#2f6ff5;padding:1px 5px;border-radius:4px;white-space:nowrap">Archive.zip</span></div>`:'');
  }
  g.innerHTML=html; g.style.opacity=go; g.style.left=gx+'px'; g.style.top=gy+'px';

  // Ablage
  const o=Math.max(0,openness(t)), sh=$('shelf');
  sh.style.opacity=C(o*2.2); sh.style.transform=`scale(${lerp(.04,1,o)},${lerp(.16,1,o)})`;
  sh.style.filter=`blur(${(1-C(o))*6}px)`;
  const img=shelfImage(t);
  // Kommt eine Kachel dazu oder geht eine weg, rücken die anderen in der App animiert nach:
  // hier weich überblendet statt hart umgeschaltet. Eine neue Auswahl wechselt sofort.
  const SOFT=new Set(['h0d>h1','h1d>h2','h4t>h5','h5>h4']);
  let prev=null, mix=1;
  for(let d=0.01; d<=0.15; d+=0.01){ const p=shelfImage(t-d); if(p!==img){ if(SOFT.has(p+'>'+img)){prev=p; mix=d/0.15;} break; } }
  // Die vorige Fassung bleibt deckend darunter, die neue blendet darüber ein: so scheint nichts durch
  for(const el of sh.querySelectorAll('img')){
    el.style.zIndex = el.id===img ? 2 : 1;
    el.style.opacity = el.id===img ? (prev ? mix : 1) : (el.id===prev ? 1 : 0);
  }
  const s=$('strip'), st=strip(t); s.style.opacity=st; s.style.width=(6*st)+'px';

  // Folie: Bilder nach dem Ablegen, ⌘Z in der Präsentation nimmt sie wieder weg (zuletzt eingefügtes zuerst)
  let p1=0; if(t>=9.5) p1=seg(t,9.5,9.65);
  let p2=0; if(t>=12.4) p2=seg(t,12.4,12.55);
  $('p1').style.opacity=p1; $('th1').style.opacity=p1; $('ph1').style.opacity=1-p1;
  $('p2').style.opacity=p2; $('th2').style.opacity=p2; $('ph2').style.opacity=1-p2;
  const dragTile=(t>=8.4&&t<9.5)||(t>=11.4&&t<12.4);
  $('ph1').classList.toggle('hot', dragTile&&inRect(px,py,PH1[0],PH1[1],210,158));
  $('ph2').classList.toggle('hot', dragTile&&inRect(px,py,PH2[0],PH2[1],210,158));

  const [kv,ko]=keys(t); const ks=$('keys'); const kk=kv.join('|');
  if(kk!==lastKeys){ks.innerHTML=kv.map(k=>`<span>${k}</span>`).join(''); lastKeys=kk;}
  ks.style.opacity=ko;
  const clicks=[1.3,3.55,8.35,11.35,14.25];
  let press=0; for(const c of clicks) if(t>=c&&t<c+0.12) press=1;
  pt.style.transform=`scale(${press?0.88:1})`;
};
window.DURATION=REAL;
render(0);
