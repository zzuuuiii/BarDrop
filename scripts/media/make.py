import json
T={
"en":{
 "hero":("A shelf at the<br>edge of your screen.","Drop anything at the edge of your screen. Drag it back out whenever you need it."),
 "actions":("One drag<br>to any action.","Drop items on AirDrop, a folder or the Trash. Folders and the Trash work like in the Finder, and ⌘Z puts things back."),
 "stacks":("Stacks keep<br>things together.","Drop several files at once and they stay together. Double-click a stack to look inside."),
 "settings":("Feels right<br>at home on a Mac.","Edge, size, actions and how files are kept, in Settings built like macOS. Light and dark."),
},
"de":{
 "hero":("Eine Ablage am Rand<br>deines Bildschirms.","Leg alles am Bildschirmrand ab und zieh es wieder heraus, wenn du es brauchst."),
 "actions":("Ein Zug<br>zur Aktion.","Leg Objekte auf AirDrop, einen Ordner oder den Papierkorb. Ordner und Papierkorb funktionieren wie im Finder, ⌘Z legt alles zurück."),
 "stacks":("Stapel halten<br>zusammen.","Mehrere Dateien auf einmal bleiben zusammen. Ein Doppelklick auf den Stapel zeigt, was drin ist."),
 "settings":("Fühlt sich an<br>wie macOS.","Rand, Größe, Aktionen und wie Dateien aufbewahrt werden, in Einstellungen im Stil von macOS. Hell und dunkel."),
}}
HEAD='<html><head><meta charset="utf-8"><link rel="stylesheet" href="base.css"><style>.shot{position:absolute}.win{position:absolute;width:436px;height:640px;border-radius:16px;overflow:hidden;box-shadow:0 30px 80px rgba(0,0,0,.5);border:1px solid rgba(255,255,255,.14)}.win img{width:436px;height:640px;display:block}.tag{position:absolute;color:#fff;font-size:15px;font-weight:600;opacity:.8}</style></head><body>'
def title(t,top=300,badge=False):
    h,p=t
    b='<div class="badge"><img src="AppIcon.png">BarDrop</div>' if badge else ''
    return f'<div class="title" style="left:110px;top:{top}px">{b}<h1>{h}</h1><p>{p}</p></div>'
# Ein Hintergrund über alle vier Bilder: Im README stehen sie als 2×2-Kachel, jedes zeigt
# seinen Ausschnitt aus einer großen Fläche, sodass der Verlauf über die Kachel weiterläuft
QUAD={"hero":(0,0),"actions":(1,0),"stacks":(0,1),"settings":(1,1)}
def wall(k):
    qx,qy=QUAD[k]
    # Wie die Website (bardrop.app): ruhiges Hellgrau #f5f5f7, darauf die dunkle Ablage
    return (f'<div style="position:absolute;left:{-1600*qx}px;top:{-1000*qy}px;width:3200px;height:2000px;background:#f5f5f7"></div>')
for lang,t in T.items():
    pages={}
    pages["hero"]=HEAD+wall("hero")+title(t["hero"],250,True)+f'<img class="shot" src="Produkt_Ablage_{lang}.png" style="right:0;top:200px;width:660px;height:900px;margin-top:-100px">'+'</body></html>'
    # actions: shelf zoomed with bar highlighted by crop
    # Aktion im Einsatz: eine Datei wird auf die Ordner-Aktion gezogen
    ghost='<div style="position:absolute;left:1334px;top:730px;width:80px;height:60px;opacity:.82;filter:drop-shadow(0 10px 18px rgba(0,0,0,.45))"><div style="width:80px;height:60px;background:url(Produkt_Aktion_'+lang+'.png) -441.25px -217.5px/550px 750px;border-radius:6px"></div></div>'
    cursor='<svg width="22" height="28" viewBox="0 0 18 22" style="position:absolute;left:1372px;top:758px"><path d="M2 2 L2 18 L6.5 14 L9.5 20.5 L12.5 19 L9.5 12.8 L15.5 12.8 Z" fill="#000" stroke="#fff" stroke-width="1.3" stroke-linejoin="round"/></svg>'
    pages["actions"]=HEAD+wall("actions")+title(t["actions"],310)+f'<img class="shot" src="Produkt_Aktion_{lang}.png" style="right:0;top:100px;width:660px;height:900px">'+ghost+cursor+'</body></html>'
    pages["stacks"]=HEAD+wall("stacks")+title(t["stacks"],330)+f'<img class="shot" src="Produkt_Stapel_{lang}.png" style="right:0;top:100px;width:660px;height:900px">'+'</body></html>'
    # Ganzes Einstellungsfenster im Dunkelmodus, mit Ampel wie in macOS
    lights='<div style="position:absolute;left:20px;top:20px;display:flex;gap:8px">'+''.join(f'<span style="width:12px;height:12px;border-radius:50%;background:{c};box-shadow:inset 0 0 0 .5px rgba(0,0,0,.25)"></span>' for c in ("#ff5f57","#febc2e","#28c840"))+'</div>'
    def window(img,left,top,border):
        return f'<div style="position:absolute;left:{left}px;top:{top}px;width:680px;height:700px;transform:scale(.78);transform-origin:top left;border-radius:16px;overflow:hidden;box-shadow:0 18px 40px -12px rgba(0,0,0,.28);border:1px solid {border}"><img src="{img}" style="width:680px;height:700px;display:block">{lights}</div>'
    # Dunkel hinten, hell davor und leicht versetzt: beide Erscheinungsbilder
    pages["settings"]=HEAD+wall("settings")+title(t["settings"],330)+window(f"Produkt_Fenster_Aktionen_{lang}.png",760,120,"rgba(255,255,255,.16)")+window(f"Produkt_Fenster_Objekte_{lang}_hell.png",990,300,"rgba(0,0,0,.18)")+'</body></html>'
    for k,v in pages.items():
        open(f"p_{k}_{lang}.html","w").write(v)
