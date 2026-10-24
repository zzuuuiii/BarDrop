import SwiftUI
import AppKit

/// Die Ablage an der Kopfzeile vom Rand ziehen: Erst dehnt sie sich wie ein Tropfen, der
/// am Rand hängt, dann löst sie sich mit einem Ruck. An einem Rand (links oder rechts)
/// losgelassen, dockt sie dort an, mit derselben Bewegung rückwärts; der Rand in den
/// Einstellungen stellt sich dabei mit um. Sonst gleitet sie an ihren Rand zurück.
/// Ablauf und Fenster: EdgeController (Abschnitt „Vom Rand ziehen“).
enum EdgeTear {
    /// Platz im Fenster links und rechts der Ablage, solange sie gezogen wird: für den
    /// Schatten und die Verbindung zum Rand
    static let reach: CGFloat = 140
    /// So weit (pt) muss man vom Rand weg ziehen, bis sich die Ablage löst
    static let tearDistance: CGFloat = 85
    /// Zusätzliche dunkle Tönung über dem Glas der losgelösten Ablage: im hellen
    /// Erscheinungsbild weniger (mittelgrau, weiße Schrift bleibt lesbar)
    static func glassDarken(light: Bool) -> Double { light ? 0.3 : 0.5 }
    /// Hell: Das helle Glas ist schon ganz da, bevor sich das Schwarz zurückzieht. Kamen
    /// beide gleichzeitig, sah die Ablage dazwischen kurz dunkelgrau und durchsichtig aus;
    /// so geht das Schwarz direkt in Weiß über (beim Andocken umgekehrt)
    static func lightCover(_ glass: Double) -> Double { max(0, min(1, glass * 2.5)) }
    /// Bis zu diesem Abstand zum Rand zieht er die Ablage wieder an
    static let attachZone: CGFloat = 70
    /// Dehnen bis zum Lösen: höchstens so weit (pt) folgt die Ablage, und so schnell wird es
    /// zäh (anfangs folgt sie gut, kurz vor dem Reißen kaum noch)
    static let stretchMax: CGFloat = 18
    static let stretchSoftness: CGFloat = 32
    /// Griff oben in der Mitte und die Fläche um ihn herum, an der man ziehen kann
    static let grabWidth: CGFloat = 120
    static let grabHeight: CGFloat = 26
    /// Eckenradius der schwebenden Ablage (wie die offene Ablage innen)
    static let cornerRadius: CGFloat = 28
    /// Bereich oben, in dem der Griff erscheint: bis ins obere Drittel des Titels (Kopfzeile:
    /// 12 pt Abstand, Zeile 30 pt, siehe ShelfContent), nicht schon an seiner Unterkante
    static let headerHeight: CGFloat = 25

    /// Umriss der Ablage: Je fester sie mit dem Rand verbunden ist, desto eckiger werden die
    /// Ecken auf seiner Seite. Angedockt hat sie dort keine Rundung, sondern geht in den Bogen
    /// zum Bildschirmrand über; so gibt es am Ende des Andockens keinen Sprung.
    static func bodyPath(_ body: CGRect, attach: CGFloat, side: ScreenEdge, grow: CGFloat = 0) -> Path {
        let edge = edgeRadius(attach: attach) + grow
        let far = cornerRadius + grow
        let left = side == .left
        return UnevenRoundedRectangle(topLeadingRadius: left ? edge : far,
                                      bottomLeadingRadius: left ? edge : far,
                                      bottomTrailingRadius: left ? far : edge,
                                      topTrailingRadius: left ? far : edge,
                                      style: .continuous)
            .path(in: body.insetBy(dx: -grow, dy: -grow))
    }

    /// Rundung der Ecken auf der Randseite
    static func edgeRadius(attach: CGFloat) -> CGFloat {
        let t = max(0, min(1, (attach - 0.55) / 0.45))
        let square = t * t * (3 - 2 * t)
        return cornerRadius * (1 - square)
    }
}

/// Die schwarze Form, solange die Ablage gezogen wird: Ablage, Verbindung und ein Stück
/// Rand verschmelzen wie Flüssigkeit (Unschärfe, dann harte Schwelle). Je weiter die
/// Ablage vom Rand weg ist, desto dünner die Verbindung, bis sie reißt.
struct TearGoo: View, Animatable {
    let tear: ShelfUIModel.Tear
    /// Platz über und unter der Ablage im Rahmen (Rand-Übergänge)
    let inset: CGFloat
    /// Platz links und rechts der Ablage im Rahmen
    let reach: CGFloat
    /// Feiner heller Rahmen wie am Rand (Einstellung „Rahmen“ bzw. in der Einführung)
    var outline = false
    /// Losgelöst aus Glas (0 schwarz wie am Rand, 1 Glas). Je näher sie einem Rand kommt,
    /// desto schwärzer, damit sie beim Andocken nahtlos in die schwarze Ablage übergeht.
    var glass: Double = 0
    /// Helles Erscheinungsbild: helles Glas statt dunklem
    var light = false
    /// Die Ablage am Rand, wie sie angedockt aussieht (Überblendung über `tear.dock`)
    var docked: EdgeBlobShape? = nil

    /// Der Übergang zu Glas wird Bild für Bild berechnet (sonst sprang der Verlauf sofort ans
    /// Ende, während das Glas erst einblendete: kurz war alles durchsichtig)
    var animatableData: Double {
        get { glass }
        set { glass = newValue }
    }

    var body: some View {
        let attach = Double(max(0, min(1, tear.attach)))
        // Wie viel Schwarz insgesamt noch da ist (für den Schatten)
        let black = 1 - glass
        ZStack {
            if glass > 0.001 {
                // Schatten nur außerhalb der Ablage: Unter dem Glas sähe man ihn sonst durch
                bodyShape
                    .fill(Color.black)
                    .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
                    // Maske reicht über den Rahmen hinaus, sonst war der Schatten unten abgeschnitten
                    .mask {
                        OutsideBodyShape(reach: reach, inset: inset, attach: tear.attach, side: tear.side)
                            .fill(style: FillStyle(eoFill: true))
                    }
                    .opacity(1 - black)
                // Das Glas selbst liegt in einem Begleitfenster darunter (ShelfGlassWindow),
                // hier nur die eigene dunkle Tönung darüber
                bodyShape
                    .fill(light ? Color.white.opacity(0.6) : Color.black.opacity(EdgeTear.glassDarken(light: false)))
                    .opacity(light ? EdgeTear.lightCover(glass) : glass)
            }
            // Überblendung zur angedockten Form: erst kommt sie dazu, dann geht die
            // verschmelzende Form; so gibt es keinen Moment, in dem es durchscheint
            let dockIn = Double(min(1, tear.dock * 2))
            let gooOut = Double(max(0, tear.dock * 2 - 1))
            // Ein gemeinsamer Schatten für beide Formen: Während der Überblendung lagen sonst
            // zwei Schatten übereinander, und er wurde kurz dunkler (im Video nachgemessen)
            ZStack {
                if glass < 0.001 {
                    // Ohne Glas ganz schwarz, ohne Verlauf: Die weiche Front ließ sonst an den
                    // Ecken der fernen Seite etwas durchscheinen
                    solid.opacity(1 - gooOut)
                } else if glass < 0.999 || attach > 0.01 {
                    // Das Schwarz zieht sich zum Rand hin zurück, als bliebe es dort hängen (beim
                    // Andocken kommt es von dort wieder)
                    solid.mask { darkness(attach: attach) }
                        .opacity(1 - gooOut)
                }
                if dockIn > 0.001, let docked {
                    DockedSpan(base: docked, reach: reach, gap: tear.gap, side: tear.side)
                        .fill(Color.black)
                        .opacity(dockIn)
                }
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 8)
            if outline {
                // Rahmen wechseln gegenläufig (sonst lagen kurz zwei Bögen übereinander).
                // Auf Glas kein eigener Rahmen: Das Glas hat seine eigene Lichtkante, beide
                // zusammen ergaben einen doppelten, durchsichtigen Rand.
                Group {
                    outlineStroke
                    if attach > 0.01 { gooRim }
                }
                .opacity((1 - dockIn) * (1 - glass))
                if dockIn > 0.001, let docked {
                    // Innen auf dem Schwarz, wie der Rahmen der angedockten Ablage
                    DockedSpan(base: Self.contour(docked), reach: reach, gap: tear.gap, side: tear.side)
                        .stroke(Color.white.opacity(0.2), lineWidth: 2)
                        .mask { DockedSpan(base: docked, reach: reach, gap: tear.gap, side: tear.side).fill(Color.black) }
                        .opacity(dockIn)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Wie schwarz die Ablage wo ist: Das Schwarz weicht von der fernen Seite zum Rand hin
    /// zurück; solange sie mit dem Rand verbunden ist, bleibt es dort an der Verbindung
    private func darkness(attach: Double) -> some View {
        let glass = self.glass
        let fromLeft = tear.side == .left
        let reach = self.reach, inset = self.inset
        // Über den Rahmen hinaus zeichnen (Schatten), dafür die Fläche größer und verschoben
        let beyond: CGFloat = 120
        return Canvas { context, size in
            let frame = CGRect(x: beyond, y: beyond, width: size.width - 2 * beyond, height: size.height - 2 * beyond)
            let body = frame.insetBy(dx: reach, dy: inset)
            guard body.width > 0, body.height > 0 else { return }
            // Schwarz kommt als weiche, leicht gewölbte Front von der Randseite: in der Mitte
            // etwas voraus, oben und unten etwas später, die Ecken zuletzt (beim Lösen
            // umgekehrt). Gezeichnet in waagrechten Streifen, je mit eigenem Verlauf, danach
            // weichgezeichnet, damit keine Stufen zu sehen sind.
            let fromEdge: (CGFloat) -> CGPoint = { x in
                CGPoint(x: fromLeft ? body.minX + x : body.maxX - x, y: 0)
            }
            // Breite des Übergangs (Anteil der Breite): schmal, sonst lag vor der Front eine
            // breite, neblige Kante, die vor allem auf hellem Glas auffiel
            let softness = 0.28
            let bulge = 0.3                         // wie weit die Mitte vorausläuft
            let travel = 1 + bulge + softness       // bis auch die Ecken ganz frei sind
            let front = travel * (1 - glass) - softness
            // Verbindung zum Rand: an der Randseite so dunkel wie die Verbindung, weich auslaufend
            let link = min(1, attach * 1.4)
            // Streifen von 2 pt auf ganzen Punkten, ohne Überlappung und ohne Kantenglättung:
            // Überlappende Ränder wurden doppelt dunkel und zeigten sich als Streifen
            let rowHeight: CGFloat = 2
            let rows = Int((size.height / rowHeight).rounded(.up))
            // Nur die Streifen, unter denen die schwarze Form liegen kann (Rahmen plus Platz für
            // die Unschärfe): Der Bereich darüber und darunter (`beyond`, für den Schatten) wurde
            // sonst in jedem Bild mitgezeichnet, gut ein Drittel der Arbeit, ohne dass man ihn
            // sah. Das kostete gerade beim Lösen (Übergang zu Glas) Bilder, und die Ablage hing
            // dem Zeiger hinterher.
            let firstRow = max(0, Int(((frame.minY - 12) / rowHeight).rounded(.down)))
            let lastRow = min(rows, Int(((frame.maxY + 12) / rowHeight).rounded(.up)))
            context.drawLayer { layer in
            layer.addFilter(.blur(radius: 4))
            for row in firstRow..<max(firstRow, lastRow) {
                let y0 = CGFloat(row) * rowHeight
                let y1 = y0 + rowHeight
                let mid = (y0 + y1) / 2
                let yn = max(-1.2, min(1.2, Double((mid - body.midY) / (body.height / 2))))
                // In dieser Höhe liegt die Front um `lag` weiter zur Randseite
                let lag = bulge * yn * yn
                let stops: [Gradient.Stop] = (0...10).map { k in
                    let x = Double(k) / 10 * 1.2
                    let t = max(0, min(1, (x + lag - front) / softness))
                    let wave = 1 - t * t * (3 - 2 * t)
                    let b = max(0, min(1, x / 0.35))
                    let band = link * (1 - b * b * (3 - 2 * b))
                    return Gradient.Stop(color: Color.black.opacity(max(wave, band)), location: Double(k) / 10)
                }
                let start = fromEdge(0), end = fromEdge(body.width * 1.2)
                layer.fill(Path(CGRect(x: 0, y: y0, width: size.width, height: rowHeight)),
                           with: .linearGradient(Gradient(stops: stops),
                                                 startPoint: CGPoint(x: start.x, y: mid),
                                                 endPoint: CGPoint(x: end.x, y: mid)),
                           style: FillStyle(antialiased: false))
            }
            }
        }
        .padding(-beyond)
    }

    /// Nur die Kontur der angedockten Form, ohne Linie am Bildschirmrand (wie ihr Rahmen)
    private static func contour(_ shape: EdgeBlobShape) -> EdgeBlobShape {
        var line = shape
        line.closed = false
        return line
    }

    /// Umriss der Ablage im Rahmen
    private var bodyShape: TearBodyShape {
        TearBodyShape(reach: reach, inset: inset, attach: tear.attach, side: tear.side)
    }

    /// Schwarze Ablage wie am Rand (angedockt, beim Dehnen, beim Andocken)
    @ViewBuilder
    private var solid: some View {
        Group {
            if tear.attach > 0.01 {
                // Mit dem Rand verbunden: verschmelzende Formen (aufwendig, nur dann)
                goo(grow: 0, color: .black)
            } else {
                // Gelöst oder schwebend: ein einfaches abgerundetes Rechteck, das kostet beim
                // Ziehen fast nichts
                // Mit Rahmen 1 pt größer: Der Rahmen liegt dann ganz auf Schwarz, ohne
                // durchscheinenden Spalt zwischen Rahmen und Fläche
                RoundedRectangle(cornerRadius: EdgeTear.cornerRadius + (outline ? 1 : 0), style: .continuous)
                    .fill(Color.black)
                    .padding(.horizontal, reach - (outline ? 1 : 0))
                    .padding(.vertical, inset - (outline ? 1 : 0))
            }
        }
    }

    /// Feiner heller Rahmen, scharf gezeichnet (nicht aus der verschmolzenen Form: dort wurde er
    /// an den Ecken zu dünn). Wo die Verbindung zum Rand ansetzt, ausgespart, wie am Rand selbst.
    private var outlineStroke: some View {
        Canvas { context, size in
            let body = CGRect(x: reach, y: inset, width: max(0, size.width - 2 * reach),
                              height: max(0, size.height - 2 * inset))
            guard body.width > 0, body.height > 0 else { return }
            let a = max(0, min(1, tear.attach))
            if a > 0.01 {
                var mask = Path(CGRect(origin: .zero, size: size))
                mask.addRect(connectionZone(body: body, size: size))
                context.clip(to: mask, style: FillStyle(eoFill: true))
            }
            let path = EdgeTear.bodyPath(body, attach: tear.attach, side: tear.side, grow: 0.5)
            context.stroke(path, with: .color(.white.opacity(0.2)), lineWidth: 1)
        }
    }

    private func goo(grow: CGFloat, color: Color) -> some View {
        Canvas { context, size in
            context.addFilter(.alphaThreshold(min: 0.5, color: color))
            context.addFilter(.blur(radius: 7))
            context.drawLayer { layer in
                drawGooShapes(layer, size: size, grow: grow)
            }
        }
    }

    /// Heller Rahmen um die Verbindung und den Bogen am Bildschirmrand (Einstellung „Rahmen“),
    /// damit er beim Andocken nicht aus dem Nichts kommt: der Saum zwischen der etwas größeren
    /// und der eigentlichen verschmolzenen Form. Nur dort, wo der scharfe Rahmen der Ablage
    /// ausgespart ist.
    private var gooRim: some View {
        Canvas { context, size in
            let body = CGRect(x: reach, y: inset, width: max(0, size.width - 2 * reach),
                              height: max(0, size.height - 2 * inset))
            guard body.width > 0, body.height > 0 else { return }
            let right = tear.side == .right
            var region = Path(CGRect(x: right ? body.maxX + 2 : 0, y: 0,
                                     width: right ? max(0, size.width - body.maxX - 2) : max(0, body.minX - 2),
                                     height: size.height))
            region.addRect(connectionZone(body: body, size: size))
            context.clip(to: region)
            context.drawLayer { outer in
                outer.addFilter(.blur(radius: 0.5))     // zuletzt: weiche Kante
                outer.addFilter(.alphaThreshold(min: 0.5, color: .white.opacity(0.2)))
                outer.addFilter(.blur(radius: 7))
                outer.drawLayer { layer in drawGooShapes(layer, size: size, grow: 1.2) }
            }
            // Die eigentliche Form wieder herausnehmen, übrig bleibt der Saum
            context.blendMode = .destinationOut
            context.drawLayer { inner in
                inner.addFilter(.alphaThreshold(min: 0.5, color: .black))
                inner.addFilter(.blur(radius: 7))
                inner.drawLayer { layer in drawGooShapes(layer, size: size, grow: 0) }
            }
        }
    }

    /// Bereich der Verbindung zum Rand: Dort ist der scharfe Rahmen ausgespart
    private func connectionZone(body: CGRect, size: CGSize) -> CGRect {
        let a = max(0, min(1, tear.attach))
        let right = tear.side == .right
        // Verbindung samt ihren weichen Übergängen (etwa so breit wie die Unschärfe)
        // Liegt die Ablage nah am Rand, verschmilzt ihre ganze Seite mit dem Bogen dort (nicht
        // nur die Verbindung): dann über die volle Höhe aussparen, sonst lagen dort Linien
        // mitten im Schwarz und der Rahmen wirkte heller
        let bridge = body.height * pow(a, 1.6) + 30
        let near = max(0, min(1, (tear.gap - 6) / 14))
        let height = size.height * (1 - near) + bridge * near
        // Nur ein schmaler Streifen an der Seite zum Rand: Bis zur Mitte ausgespart fehlte
        // der Rahmen oben und unten auf halber Breite und wuchs beim Lösen von den Ecken
        // her nach (bei großer Ablage deutlich zu sehen), angedockt war er dann plötzlich da
        let cut: CGFloat = 14
        return CGRect(x: right ? body.maxX - cut : 0, y: body.midY - height / 2,
                      width: right ? size.width - (body.maxX - cut) : body.minX + cut, height: height)
    }

    /// Die verschmelzenden Formen: Ablage, Verbindung und der Bogen am Bildschirmrand
    private func drawGooShapes(_ layer: GraphicsContext, size: CGSize, grow: CGFloat) {
        let body = CGRect(x: reach, y: inset, width: max(0, size.width - 2 * reach),
                          height: max(0, size.height - 2 * inset))
        guard body.width > 0, body.height > 0 else { return }
        layer.fill(EdgeTear.bodyPath(body, attach: tear.attach, side: tear.side, grow: grow),
                   with: .color(.black))
        let a = max(0, min(1, tear.attach))
        guard a > 0.01 else { return }
        let right = tear.side == .right
        let edgeX = right ? body.maxX + tear.gap : body.minX - tear.gap
        // Über den Rand hinaus, damit dort keine Rundung entsteht (liegt außerhalb
        // des Bildschirms)
        let beyond: CGFloat = 30
        // Verbindung: von der Mitte der Ablage bis über den Rand, je loser, desto dünner
        let bridgeHeight = body.height * pow(a, 1.6) + 2 * grow
        if bridgeHeight > 1 {
            let from = right ? body.midX : edgeX - beyond
            let to = right ? edgeX + beyond : body.midX
            layer.fill(Path(CGRect(x: from, y: body.midY - bridgeHeight / 2,
                                   width: to - from, height: bridgeHeight)),
                       with: .color(.black))
        }
        // Ein Stück Rand, das sich herauswölbt: oben und unten etwas länger als die
        // Ablage, so laufen die Übergänge weich aus wie sonst am Rand
        let stubHeight = (body.height + 2 * inset) * (0.3 + 0.7 * a) + 2 * grow
        let stubWidth = 2 * (6 + 12 * a) + 2 * grow
        layer.fill(Path(ellipseIn: CGRect(x: edgeX - stubWidth / 2, y: body.midY - stubHeight / 2,
                                          width: stubWidth, height: stubHeight)),
                   with: .color(.black))
        layer.fill(Path(CGRect(x: right ? edgeX : edgeX - beyond, y: body.midY - stubHeight / 2,
                               width: beyond, height: stubHeight)),
                   with: .color(.black))
    }
}

/// Die losgelöste Ablage im größeren Fenster: abgerundetes Rechteck in der Mitte
struct TearBodyShape: Shape {
    let reach: CGFloat
    let inset: CGFloat
    var attach: CGFloat = 0
    var side: ScreenEdge = .left

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: reach, dy: inset)
        guard body.width > 0, body.height > 0 else { return Path() }
        return EdgeTear.bodyPath(body, attach: attach, side: side)
    }
}

/// Fläche über den eigenen Rahmen hinaus (für Masken, die den Schatten nicht abschneiden)
struct BeyondFrameShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -120, dy: -120))
    }
}

/// Alles außer der losgelösten Ablage, über den Rahmen hinaus (mit eoFill)
struct OutsideBodyShape: Shape {
    let reach: CGFloat
    let inset: CGFloat
    var attach: CGFloat = 0
    var side: ScreenEdge = .left

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -120, dy: -120))
        path.addPath(TearBodyShape(reach: reach, inset: inset, attach: attach, side: side).path(in: rect))
        return path
    }
}

/// Die angedockte Form, vom Bildschirmrand bis zur fernen Seite der Ablage: Solange sie noch
/// ein paar Punkte vom Rand entfernt ist, reichen die Bögen schon bis an den Rand
struct DockedSpan: Shape {
    let base: EdgeBlobShape
    let reach: CGFloat
    let gap: CGFloat
    let side: ScreenEdge

    func path(in rect: CGRect) -> Path {
        let width = max(0, rect.width - 2 * reach) + max(0, gap)
        let x = side == .left ? rect.minX + reach - max(0, gap) : rect.minX + reach
        return base.path(in: CGRect(x: x, y: rect.minY, width: width, height: rect.height))
    }
}
