// WinterIsComing — snow on your Mac desktop.
// Snow piles up on top of windows, the Dock and the bottom of the screen and flies off when you drag a
// window. Hover over the snow to roll snowballs, push them into each other, drag them with the mouse and
// stack three of them into a snowman. See README.md for the full list.
// Build: swiftc -O WinterIsComing.swift -o WinterIsComing
// Run:   ./WinterIsComing   (a ❄︎ icon appears in the menu bar: pause / snow amount / quit)

import Cocoa
import SpriteKit
import Carbon

// MARK: - Settings (feel free to tweak)

enum Cfg {
    static var targetFlakes = 260            // number of flakes falling at the same time
    static let colW: CGFloat = 3             // width of one column of the snow height map (px)
    static let windowPileMax: CGFloat = 16   // max snow height on top of a window
    static let groundPileMax: CGFloat = 34   // max snow height at the bottom of the screen
    static let gravity: CGFloat = 900        // gravity for snow sliding off
    static let pollInterval = 1.0 / 30.0     // how often window positions are checked (s)
    static let maxClumps = 900               // max number of falling snow clumps at once
    static let dockPileMax: CGFloat = 18     // max snow height on the Dock
    static let dockPad: CGFloat = 4          // extra width of the Dock pile on each side of the icon area
    static let dockTopOffset: CGFloat = -1   // lower it if the snow floats above the Dock, raise it if it sinks in
    static let fallSpeed: CGFloat = 1.5      // falling speed multiplier (1 = original, bigger = faster)
    static let plowScale: CGFloat = 0.9      // size of the snowplow truck (Option+C)
    static let plowSpeed: CGFloat = 120      // top speed of the snowplow (points per second)
    static var santaScale: CGFloat = 0.8        // size of Santa's sleigh and reindeer (Option+S)
    static var santaSpeed: CGFloat = 120        // points per second across the sky
    static var treeScale: CGFloat = 1.0         // size of the Christmas tree (Option+T)
    static var snowmanLights = true          // twinkling string lights on every snowman (menu: Snowman Lights)
    static let kidScale: CGFloat = 1.0       // size of the kids (Option+P); 1 = about 62 points tall
    static let kidWalkSpeed: CGFloat = 60    // how fast the kids walk (points per second)
    static let kidPlayTime: CGFloat = 45     // seconds the kids play before they wave and go home
    static let flakesInFront = true          // some of the smallest flakes fall in front of windows, so they can reach the Dock
    static let inFrontFraction: CGFloat = 0.4 // share of the smallest layer that falls in front (0...1)
    static let ballStartRadius: CGFloat = 3  // a new snowball starts this small
    static let ballMaxRadius: CGFloat = 28   // and stops growing at this size
    static let maxBalls = 20                 // oldest resting snowballs are removed beyond this
    static let dockGain: CGFloat = 3.0       // snow landing on the Dock counts this many times more, so it builds up
}

// MARK: - Find the Dock (needs Accessibility permission)

@MainActor final class DockTracker {
    private var trusted = false
    private var warned = false
    var lastError = ""

    init() {
        // On first run macOS shows a prompt asking you to grant the permission
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(opts)
    }

    /// Frame of the Dock icon area (global macOS coordinates, origin top-left); nil if unavailable
    func frame() -> CGRect? {
        if !trusted {
            trusted = AXIsProcessTrusted()
            if !trusted {
                if !warned {
                    warned = true
                    print("❄︎ For snow on the Dock: System Settings → Privacy & Security → Accessibility, enable Terminal (or whichever app you run this from), then restart.")
                }
                lastError = "no Accessibility permission"
                return nil
            }
        }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            lastError = "Dock process not found"
            return nil
        }
        let axApp = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXChildrenAttribute as CFString, &childrenRef)
        guard err == .success, let children = childrenRef as? [AXUIElement] else {
            lastError = "could not read Dock children (AXError \(err.rawValue))"
            return nil
        }
        var roles: [String] = []
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? "?"
            roles.append(role)
            guard role == kAXListRole else { continue }
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let pv = posRef, let sv = sizeRef,
                  CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() else { continue }
            var pos = CGPoint.zero
            var sz = CGSize.zero
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
            AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            return CGRect(origin: pos, size: sz)
        }
        lastError = "no AXList among Dock children (roles: \(roles))"
        return nil
    }
}

// Three depth layers: far = small, faint, slow; near = big, bright, fast
struct Layer {
    let size: ClosedRange<CGFloat>
    let speed: ClosedRange<CGFloat>
    let alpha: ClosedRange<CGFloat>
    let sway: ClosedRange<CGFloat>
    let wind: CGFloat
    let z: CGFloat
}

let layers: [Layer] = [
    Layer(size: 1.8...3.0, speed: 22...38,  alpha: 0.30...0.50, sway: 5...10,  wind: 0.5, z: 1),
    Layer(size: 3.0...4.8, speed: 40...65,  alpha: 0.60...0.80, sway: 9...16,  wind: 0.8, z: 2),
    Layer(size: 4.8...7.5, speed: 70...105, alpha: 0.85...1.00, sway: 14...24, wind: 1.1, z: 7),
]

@inline(__always) func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { CGFloat.random(in: a...b) }

// Soft round flake texture: solid center, fading edge
@MainActor func makeFlakeTexture() -> SKTexture {
    let s: CGFloat = 64
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        let colors = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1.0),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.6),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.45, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        let c = CGPoint(x: s / 2, y: s / 2)
        ctx.drawRadialGradient(grad, startCenter: c, startRadius: 0, endCenter: c, endRadius: s / 2, options: [])
        return true
    }
    return SKTexture(image: img)
}

// Snowball body: lit from the top-left, bluish shade at the bottom-right (this part never rotates)
@MainActor func makeSnowballTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 1, y: 1, width: s - 2, height: s - 2))
        ctx.clip()
        let colors = [
            CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
            CGColor(red: 0.94, green: 0.96, blue: 1.00, alpha: 1),
            CGColor(red: 0.68, green: 0.75, blue: 0.88, alpha: 1),
        ] as CFArray
        let locs: [CGFloat] = [0, 0.55, 1]
        guard let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locs) else { return false }
        ctx.drawRadialGradient(grad,
                               startCenter: CGPoint(x: s * 0.38, y: s * 0.64), startRadius: 0,
                               endCenter: CGPoint(x: s * 0.5, y: s * 0.5), endRadius: s * 0.55,
                               options: [.drawsAfterEndLocation])
        return true
    }
    return SKTexture(image: img)
}

// Little grey-blue specks on top of the body; this layer rotates so you can see the ball roll
@MainActor func makeSpeckTexture() -> SKTexture {
    let s: CGFloat = 128
    let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addEllipse(in: CGRect(x: 6, y: 6, width: s - 12, height: s - 12))
        ctx.clip()
        for _ in 0..<30 {
            let d = rnd(3, 8)
            ctx.setFillColor(CGColor(red: 0.66, green: 0.73, blue: 0.87, alpha: rnd(0.25, 0.55)))
            ctx.fillEllipse(in: CGRect(x: rnd(6, s - 14), y: rnd(6, s - 14), width: d, height: d))
        }
        return true
    }
    return SKTexture(image: img)
}

// MARK: - Snowball

@MainActor final class Snowball {
    let node = SKNode()
    let body: SKSpriteNode
    let specks: SKSpriteNode
    var x: CGFloat = 0
    var y: CGFloat = 0
    var r: CGFloat = Cfg.ballStartRadius
    weak var pile: Pile?         // the surface it rests on (nil while falling, dragged or stacked)
    weak var below: Snowball?    // the ball it is stacked on (snowman), if any
    var falling = false
    var dragging = false
    var vel = CGVector.zero
    var decor: SKNode?           // snowman face / scarf / buttons drawn on this ball

    init(body bodyTex: SKTexture, specks speckTex: SKTexture) {
        body = SKSpriteNode(texture: bodyTex)
        specks = SKSpriteNode(texture: speckTex)
        specks.zPosition = 0.1
        specks.zRotation = rnd(0, 6.28)
        node.zPosition = 6.5
        node.addChild(body)
        node.addChild(specks)
    }

    func layout() {
        node.position = CGPoint(x: x, y: y)
        let d = CGSize(width: r * 2, height: r * 2)
        body.size = d
        specks.size = d
    }

    func drop(vel v: CGVector) {
        falling = true
        dragging = false
        pile = nil
        below = nil
        vel = v
    }
}

// MARK: - Flake

@MainActor final class Flake {
    let node: SKSpriteNode
    var vel = CGVector.zero
    var size: CGFloat = 4
    var swayAmp: CGFloat = 0
    var swayFreq: CGFloat = 1
    var phase: CGFloat = 0
    var windFactor: CGFloat = 1
    var inFront = false          // true = falls in front of windows (ignores them), lands on Dock / ground
    var isClump = false          // true = clump sliding off a surface (affected by gravity)
    var ignoreID = -1            // don't land right back on the surface it came from
    var ignoreUntil: CGFloat = 0

    init(texture: SKTexture) { node = SKSpriteNode(texture: texture) }
}

// MARK: - Snow pile (a height map drawn as a smooth white mound)

@MainActor final class Pile {
    var minX: CGFloat
    var topY: CGFloat
    let width: CGFloat
    let maxH: CGFloat
    var h: [CGFloat]
    var caps: [CGFloat]          // max height per column, tapering at both ends so it looks rounded
    var occ: [Bool]              // whether this column is hidden behind a window in front
    let body = SKShapeNode()
    let shade = SKShapeNode()
    var dirty = false

    init(minX: CGFloat, topY: CGFloat, width: CGFloat, maxH: CGFloat, parent: SKNode) {
        self.minX = minX
        self.topY = topY
        self.width = width
        self.maxH = maxH
        let n = max(1, Int((width / Cfg.colW).rounded(.up)))
        h = Array(repeating: 0, count: n)
        occ = Array(repeating: false, count: n)
        caps = (0..<n).map { i in
            let edgeDist = min(CGFloat(i) + 0.5, CGFloat(n - i) - 0.5) * Cfg.colW
            let t = min(1, edgeDist / (maxH * 2.2))
            return maxH * t.squareRoot()
        }
        body.fillColor = NSColor(calibratedWhite: 1, alpha: 0.97)
        body.strokeColor = .clear
        body.lineWidth = 0
        body.zPosition = 5
        // light blue-grey layer underneath, like a shadow
        shade.fillColor = NSColor(calibratedRed: 0.70, green: 0.78, blue: 0.92, alpha: 0.9)
        shade.strokeColor = .clear
        shade.lineWidth = 0
        shade.zPosition = 4
        shade.position = CGPoint(x: 0, y: -1.5)
        parent.addChild(shade)
        parent.addChild(body)
    }

    var count: Int { h.count }
    var total: CGFloat { h.reduce(0, +) }

    func col(at x: CGFloat) -> Int? {
        let c = Int((x - minX) / Cfg.colW)
        return (c >= 0 && c < count) ? c : nil
    }
    func colX(_ c: Int) -> CGFloat { minX + (CGFloat(c) + 0.5) * Cfg.colW }
    func surface(_ c: Int) -> CGFloat { topY + h[c] }

    func add(at c: Int, amount: CGFloat) {
        let spread: [(Int, CGFloat)] = [(0, 1), (-1, 0.75), (1, 0.75), (-2, 0.45), (2, 0.45), (-3, 0.2), (3, 0.2)]
        for (o, w) in spread {
            let i = c + o
            guard i >= 0, i < count, !occ[i] else { continue }
            h[i] = min(caps[i], h[i] + amount * w)
        }
        dirty = true
    }

    // let snow slump sideways where the slope is too steep
    func relax() -> Bool {
        guard count > 1 else { return false }
        var moved = false
        for i in 0..<(count - 1) where !occ[i] && !occ[i + 1] {
            let d = h[i] - h[i + 1]
            if abs(d) > 1.0 {
                let m = (abs(d) - 1.0) * 0.3 * (d > 0 ? 1 : -1)
                h[i] = max(0, min(caps[i], h[i] - m))
                h[i + 1] = max(0, min(caps[i + 1], h[i + 1] + m))
                if abs(m) > 0.02 { moved = true }
            }
        }
        return moved
    }

    func clear() {
        for i in 0..<count { h[i] = 0 }
        dirty = true
    }

    func redraw() {
        guard dirty else { return }
        dirty = relax()
        if total < 0.5 {
            body.path = nil
            shade.path = nil
            return
        }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: minX, y: topY))
        for c in 0..<count { p.addLine(to: CGPoint(x: colX(c), y: topY + h[c])) }
        p.addLine(to: CGPoint(x: minX + width, y: topY))
        p.closeSubpath()
        body.path = p
        shade.path = p
    }

    func remove() {
        body.removeFromParent()
        shade.removeFromParent()
    }
}

// MARK: - Scene

final class SnowScene: SKScene {
    var flakes: [Flake] = []
    var pool: [Flake] = []
    var piles: [Int: Pile] = [:]                 // window number -> snow on top of it
    var lastRect: [Int: CGRect] = [:]
    var order: [(id: Int, rect: CGRect)] = []    // windows from front to back
    var ground: Pile?
    var tex: SKTexture?
    var lastT: TimeInterval = 0
    var pollAcc: CGFloat = 0
    var t: CGFloat = 0
    let myPID = getpid()
    let world = SKNode()
    let dockTracker = DockTracker()
    var dockPile: Pile?
    var dockRect: CGRect?
    var dockAcc: CGFloat = 1
    var lastDockStatus = ""
    var balls: [Snowball] = []
    weak var activeBall: Snowball?
    var lastMouse = NSEvent.mouseLocation
    var ballTex: SKTexture?
    var dragBall: Snowball?
    var dragTarget = CGPoint.zero
    var dragOffset = CGPoint.zero
    var dragVel = CGVector.zero
    var speckTex: SKTexture?
    var plow: Plow?
    var plowDir: CGFloat = 1                     // next plow drives this way (+1 = to the right)
    var plowTex: (body: SKTexture, wheel: SKTexture)?
    var kids: [Kid] = []
    var kidBalls: [KidBall] = []
    var sleds: [Sled] = []
    var kidsClock: CGFloat = 0
    var kidsExit: CGFloat = 0                    // where the kids came from, and go back to
    var kidsCenter: CGFloat = 0
    var kidsArea: (CGFloat, CGFloat) = (0, 0)
    static let dockID = -2
    static let plowSprayID = -4
    var tree: ChristmasTree?
    var treeTex: SKTexture?
    var santa: SantaSleigh?
    var santaTex: (sleigh: SKTexture, deer: SKTexture)?
    var santaDir: CGFloat = 1
    var fallingGifts: [FallingGift] = []
    static let giftGravity: CGFloat = 420

    override func didMove(to view: SKView) {
        backgroundColor = .clear
        tex = makeFlakeTexture()
        ballTex = makeSnowballTexture()
        speckTex = makeSpeckTexture()
        addChild(world)
        resetGround()
        for _ in 0..<Cfg.targetFlakes { spawnFlake(y: rnd(0, size.height)) }
    }

    override func didChangeSize(_ oldSize: CGSize) {
        guard tex != nil else { return }
        resetGround()
    }

    func resetGround() {
        for b in balls where b.pile === ground { b.drop(vel: .zero) }
        ground?.remove()
        ground = Pile(minX: 0, topY: 0, width: size.width, maxH: Cfg.groundPileMax, parent: world)
    }

    func clearAll() {
        for p in piles.values { p.clear(); p.redraw() }
        dockPile?.clear()
        dockPile?.redraw()
        ground?.clear()
        ground?.redraw()
        for b in balls { b.node.removeFromParent() }
        balls.removeAll()
    }

    // MARK: Flake pool

    func obtain() -> Flake {
        let f = pool.popLast() ?? Flake(texture: tex!)
        world.addChild(f.node)
        flakes.append(f)
        return f
    }

    func recycle(at i: Int) {
        let f = flakes[i]
        f.node.removeFromParent()
        flakes.swapAt(i, flakes.count - 1)
        flakes.removeLast()
        pool.append(f)
    }

    func spawnFlake(y: CGFloat? = nil) {
        let f = obtain()
        let r = CGFloat.random(in: 0...1)
        let li = r < 0.40 ? 0 : (r < 0.68 ? 1 : 2)   // 40% far, 28% middle, 32% near
        let L = layers[li]
        f.inFront = Cfg.flakesInFront && li == 0 && CGFloat.random(in: 0...1) < Cfg.inFrontFraction
        f.isClump = false
        f.ignoreID = -1
        f.size = CGFloat.random(in: L.size)
        f.vel = CGVector(dx: 0, dy: -CGFloat.random(in: L.speed) * Cfg.fallSpeed)
        f.swayAmp = CGFloat.random(in: L.sway)
        f.swayFreq = rnd(0.6, 1.6)
        f.phase = rnd(0, 6.28)
        f.windFactor = L.wind
        f.node.alpha = CGFloat.random(in: L.alpha)
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = L.z
        f.node.position = CGPoint(x: rnd(-40, size.width + 40), y: y ?? size.height + rnd(2, 30))
    }

    func spawnClump(at p: CGPoint, vel: CGVector, sourceID: Int) {
        let f = obtain()
        f.isClump = true
        f.inFront = false
        f.size = rnd(2.5, 5)
        f.vel = vel
        f.ignoreID = sourceID
        f.ignoreUntil = t + 0.35
        f.node.alpha = 0.95
        f.node.size = CGSize(width: f.size * 2.2, height: f.size * 2.2)
        f.node.zPosition = 6
        f.node.position = p
    }

    // Turn a pile into falling clumps; vel is the window's velocity, so faster drags fling snow farther
    func release(_ p: Pile, vel: CGVector, id: Int) {
        let fling = CGVector(dx: max(-900, min(900, vel.dx * 0.5)),
                             dy: max(-300, min(500, vel.dy * 0.4)))
        // Snowballs sitting on this surface get flung off too
        for b in balls where b.pile === p {
            b.drop(vel: CGVector(dx: fling.dx + rnd(-30, 30), dy: fling.dy + rnd(20, 80)))
        }
        let total = p.total
        guard total > 0.5 else { p.clear(); return }
        let budget = CGFloat(max(0, Cfg.maxClumps - flakes.count + Cfg.targetFlakes))
        let k = min(1, budget / max(1, total / 3.5))
        for c in 0..<p.count where p.h[c] > 0.6 {
            var amount = p.h[c] / 3.5 * k
            while amount > 0 {
                if amount < 1 && CGFloat.random(in: 0...1) > amount { break }
                spawnClump(at: CGPoint(x: p.colX(c) + rnd(-1.5, 1.5), y: p.topY + rnd(0, p.h[c])),
                           vel: CGVector(dx: fling.dx + rnd(-40, 40), dy: fling.dy + rnd(10, 80)),
                           sourceID: id)
                amount -= 1
            }
        }
        p.clear()
    }

    // MARK: Per-frame update

    override func update(_ currentTime: TimeInterval) {
        if lastT == 0 { lastT = currentTime }
        let dt = CGFloat(min(currentTime - lastT, 1.0 / 20.0))
        lastT = currentTime
        t += dt
        pollAcc += dt
        if Double(pollAcc) >= Cfg.pollInterval {
            pollWindows(dt: pollAcc)
            pollAcc = 0
        }
        stepFlakes(dt)
        stepPlow(dt)
        stepKids(dt)
        stepTree(dt)
        stepSanta(dt)
        stepGifts(dt)
        updateMouseCapture()
        if let b = dragBall { stepDrag(b, dt) } else { updateRolling() }
        stepBalls(dt)
    }

    // MARK: Dragging & snowmen

    /// The overlay normally lets every click through. Only while the mouse is over a snowball (or dragging one)
    /// does it catch clicks, so you can grab the ball without clicking the window underneath.
    func updateMouseCapture() {
        guard let w = view?.window else { return }
        let capture = dragBall != nil || ballAt(NSEvent.mouseLocation) != nil
        if w.ignoresMouseEvents == capture { w.ignoresMouseEvents = !capture }
    }

    /// The visible, resting snowball under a point (top of a stack first)
    func ballAt(_ m: CGPoint) -> Snowball? {
        var best: Snowball?
        for b in balls where !b.falling && !b.node.isHidden {
            let dx = m.x - b.x, dy = m.y - b.y
            if dx * dx + dy * dy <= (b.r + 2) * (b.r + 2), best == nil || b.y > best!.y { best = b }
        }
        return best
    }

    func above(_ b: Snowball) -> Snowball? { balls.first { $0.below === b } }

    func base(of b: Snowball) -> Snowball {
        var x = b
        while let y = x.below { x = y }
        return x
    }

    /// Balls in a stack from the bottom up
    func stack(from base: Snowball) -> [Snowball] {
        var out = [base]
        while let a = above(out.last!), out.count < 10 { out.append(a) }
        return out
    }

    override func mouseDown(with event: NSEvent) {
        let m = event.location(in: self)
        guard let b = ballAt(m) else { return }
        // Anything stacked on top of the grabbed ball tumbles off
        var a = above(b)
        while let x = a {
            a = above(x)
            x.drop(vel: CGVector(dx: rnd(-50, 50), dy: rnd(40, 100)))
        }
        removeDecor(stackOf: b)
        b.pile = nil
        b.below = nil
        b.dragging = true
        b.node.zPosition = 8                 // in front while dragging
        dragBall = b
        activeBall = nil
        dragOffset = CGPoint(x: b.x - m.x, y: b.y - m.y)
        dragTarget = m
        dragVel = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        dragTarget = event.location(in: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard let b = dragBall else { return }
        dragBall = nil
        b.dragging = false
        if let target = stackTarget(for: b) {
            b.below = target
            b.vel = .zero
            let st = stack(from: base(of: b))
            for (i, x) in st.enumerated() { x.node.zPosition = 6.5 + CGFloat(i) * 0.3 }
            if st.count == 3 { makeSnowman(st) }
        } else {
            b.node.zPosition = 6.5
            // Let go: it falls (with a bit of the throw) and lands on whatever is below
            b.drop(vel: CGVector(dx: max(-600, min(600, dragVel.dx * 0.5)),
                                 dy: max(-400, min(400, dragVel.dy * 0.5))))
        }
    }

    func stepDrag(_ b: Snowball, _ dt: CGFloat) {
        let target = CGPoint(x: dragTarget.x + dragOffset.x, y: dragTarget.y + dragOffset.y)
        if dt > 0 {
            let v = CGVector(dx: (target.x - b.x) / dt, dy: (target.y - b.y) / dt)
            dragVel = CGVector(dx: dragVel.dx * 0.7 + v.dx * 0.3, dy: dragVel.dy * 0.7 + v.dy * 0.3)
        }
        b.specks.zRotation -= (target.x - b.x) / b.r
        b.x = target.x
        b.y = target.y
        lastMouse = NSEvent.mouseLocation
    }

    /// A ball dropped just above another ball (that isn't already a full snowman) gets stacked on it
    func stackTarget(for b: Snowball) -> Snowball? {
        var best: Snowball?
        var bestDist = CGFloat.greatestFiniteMagnitude
        for c in balls where c !== b && !c.falling && !c.dragging && !c.node.isHidden {
            guard above(c) == nil, stack(from: base(of: c)).count < 3 else { continue }
            let dx = abs(b.x - c.x), dy = b.y - c.y
            guard dx < c.r * 0.9 + b.r * 0.3, dy > 0, dy < c.r + b.r + 30 else { continue }
            if dx < bestDist { best = c; bestDist = dx }
        }
        return best
    }

    func removeDecor(stackOf b: Snowball) {
        for x in stack(from: base(of: b)) {
            x.decor?.removeFromParent()
            x.decor = nil
        }
    }

    /// Three stacked balls become a snowman: face and scarf on the head, buttons and stick arms on the body
    func makeSnowman(_ st: [Snowball]) {
        let body = st[1], head = st[2]
        removeDecor(stackOf: head)
        let R = head.r

        let h = SKNode()
        h.zPosition = 0.5
        for sx in [-1.0, 1.0] as [CGFloat] {
            let eye = SKShapeNode(circleOfRadius: max(1, R * 0.09))
            eye.fillColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            eye.strokeColor = .clear
            eye.position = CGPoint(x: sx * R * 0.3, y: R * 0.22)
            h.addChild(eye)
        }
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: R * 0.02, y: R * 0.06))
        nose.addLine(to: CGPoint(x: R * 0.75, y: -R * 0.04))
        nose.addLine(to: CGPoint(x: R * 0.02, y: -R * 0.12))
        nose.closeSubpath()
        let carrot = SKShapeNode(path: nose)
        carrot.fillColor = NSColor(calibratedRed: 0.96, green: 0.52, blue: 0.13, alpha: 1)
        carrot.strokeColor = .clear
        h.addChild(carrot)
        for k in 0..<5 {
            let a = CGFloat.pi * (1.2 + 0.15 * CGFloat(k))
            let dot = SKShapeNode(circleOfRadius: max(0.7, R * 0.05))
            dot.fillColor = NSColor(calibratedWhite: 0.1, alpha: 1)
            dot.strokeColor = .clear
            dot.position = CGPoint(x: cos(a) * R * 0.42, y: sin(a) * R * 0.42 - R * 0.05)
            h.addChild(dot)
        }
        let red = NSColor(calibratedRed: 0.82, green: 0.16, blue: 0.18, alpha: 1)
        let scarf = SKShapeNode(rect: CGRect(x: -R * 0.85, y: -R * 0.98, width: R * 1.7, height: R * 0.3),
                                cornerRadius: R * 0.12)
        scarf.fillColor = red
        scarf.strokeColor = .clear
        h.addChild(scarf)
        let tail = SKShapeNode(rect: CGRect(x: R * 0.3, y: -R * 1.55, width: R * 0.28, height: R * 0.7),
                               cornerRadius: R * 0.08)
        tail.fillColor = red
        tail.strokeColor = .clear
        tail.zRotation = -0.15
        h.addChild(tail)
        head.node.addChild(h)
        head.decor = h

        let B = body.r
        let bd = SKNode()
        bd.zPosition = 0.5
        for k in 0..<3 {
            let btn = SKShapeNode(circleOfRadius: max(0.8, B * 0.07))
            btn.fillColor = NSColor(calibratedWhite: 0.08, alpha: 1)
            btn.strokeColor = .clear
            btn.position = CGPoint(x: 0, y: B * (0.35 - 0.33 * CGFloat(k)))
            bd.addChild(btn)
        }
        let brown = NSColor(calibratedRed: 0.42, green: 0.28, blue: 0.16, alpha: 1)
        for sx in [-1.0, 1.0] as [CGFloat] {
            let arm = CGMutablePath()
            arm.move(to: CGPoint(x: sx * B * 0.85, y: B * 0.15))
            arm.addLine(to: CGPoint(x: sx * B * 1.75, y: B * 0.65))
            arm.move(to: CGPoint(x: sx * B * 1.4, y: B * 0.45))
            arm.addLine(to: CGPoint(x: sx * B * 1.55, y: B * 0.85))
            let stick = SKShapeNode(path: arm)
            stick.strokeColor = brown
            stick.lineWidth = max(1.2, B * 0.09)
            stick.lineCap = .round
            bd.addChild(stick)
        }
        body.node.addChild(bd)
        body.decor = bd
        addLights(base: st[0], body: body)
    }

    /// A strand of colored lights draped across the body and another across the base, each bulb
    /// twinkling on its own, plus a warm glow on the snow at the snowman's feet
    func addLights(base: Snowball, body: Snowball) {
        guard let glowTex = tex else { return }
        let colors: [NSColor] = [nsHex(0xffd27a), nsHex(0xff5a4e), nsHex(0x66e08a), nsHex(0x63a9ff),
                                 nsHex(0xff9ad5), nsHex(0xfff1c9)]
        var colorIndex = Int.random(in: 0..<colors.count)

        func strand(on ball: Snowball, from a: CGPoint, to b: CGPoint, sag c: CGPoint, bulbs n: Int) -> SKNode {
            let r = ball.r
            let holder = SKNode()
            holder.name = "lights"
            holder.zPosition = 0.6
            holder.isHidden = !Cfg.snowmanLights
            let A = CGPoint(x: a.x * r, y: a.y * r), B = CGPoint(x: b.x * r, y: b.y * r), C = CGPoint(x: c.x * r, y: c.y * r)
            let wirePath = CGMutablePath()
            wirePath.move(to: A)
            wirePath.addQuadCurve(to: B, control: C)
            let wire = SKShapeNode(path: wirePath)
            wire.strokeColor = nsHex(0x1f3d2a)
            wire.lineWidth = max(0.8, r * 0.05)
            holder.addChild(wire)
            for i in 0..<n {
                let t = 0.08 + 0.84 * CGFloat(i) / CGFloat(max(1, n - 1))
                let pt = CGPoint(x: (1 - t) * (1 - t) * A.x + 2 * (1 - t) * t * C.x + t * t * B.x,
                                 y: (1 - t) * (1 - t) * A.y + 2 * (1 - t) * t * C.y + t * t * B.y - max(0.8, r * 0.05))
                let color = colors[colorIndex % colors.count]
                colorIndex += 1
                // Soft glow around the bulb, twinkling at its own pace
                let glow = SKSpriteNode(texture: glowTex, size: CGSize(width: r * 0.75 + 5, height: r * 0.75 + 5))
                glow.color = color
                glow.colorBlendFactor = 1
                glow.blendMode = .add
                glow.position = pt
                glow.alpha = 0.9
                let low = rnd(0.25, 0.55), slow = Double(rnd(0.5, 1.4))
                glow.run(.sequence([.wait(forDuration: Double(rnd(0, 1.2))),
                                    .repeatForever(.sequence([.fadeAlpha(to: low, duration: slow),
                                                              .fadeAlpha(to: 1, duration: slow * Double(rnd(0.6, 1.2)))]))]))
                holder.addChild(glow)
                let bulb = SKShapeNode(ellipseOf: CGSize(width: max(2.2, r * 0.15), height: max(2.8, r * 0.19)))
                bulb.fillColor = color
                bulb.strokeColor = .clear
                bulb.position = pt
                bulb.zPosition = 0.01
                holder.addChild(bulb)
            }
            return holder
        }

        // On the body: hangs below the scarf, over the buttons
        body.decor?.addChild(strand(on: body, from: CGPoint(x: -0.92, y: 0.4), to: CGPoint(x: 0.92, y: 0.15),
                                    sag: CGPoint(x: 0, y: -0.45), bulbs: 6))
        // On the base: a longer strand, and a warm glow on the snow around the feet
        let baseDecor = SKNode()
        baseDecor.zPosition = 0.5
        baseDecor.addChild(strand(on: base, from: CGPoint(x: -0.94, y: 0.32), to: CGPoint(x: 0.94, y: 0.12),
                                  sag: CGPoint(x: 0, y: -0.5), bulbs: 8))
        let halo = SKSpriteNode(texture: glowTex, size: CGSize(width: base.r * 6, height: base.r * 2.4))
        halo.name = "lights"
        halo.color = nsHex(0xffc27a)
        halo.colorBlendFactor = 1
        halo.blendMode = .add
        halo.alpha = 0.35
        halo.position = CGPoint(x: 0, y: -base.r * 0.85)
        halo.zPosition = -0.6
        halo.isHidden = !Cfg.snowmanLights
        baseDecor.addChild(halo)
        base.node.addChild(baseDecor)
        base.decor = baseDecor
    }

    /// Turn the lights on every snowman on or off
    func setSnowmanLights(_ on: Bool) {
        Cfg.snowmanLights = on
        for b in balls {
            b.decor?.enumerateChildNodes(withName: "//lights") { n, _ in n.isHidden = !on }
            if b.decor?.name == "lights" { b.decor?.isHidden = !on }
        }
    }

    // MARK: Snowballs

    /// Is the mouse inside the snow band of this pile (a bit below the edge up to a bit above the snow)?
    func mouseOver(_ p: Pile, _ m: CGPoint) -> Bool {
        guard let c = p.col(at: m.x), !p.occ[c] else { return false }
        return m.y >= p.topY - 6 && m.y <= p.topY + p.h[c] + 14
    }

    /// Which snow surface is the mouse hovering over? Dock first, then windows front to back, then the ground.
    func surfaceUnderMouse(_ m: CGPoint) -> Pile? {
        // Hovering over a snowball counts as hovering over the snow it sits on. Without this, a big ball
        // stops rolling as soon as the cursor rises above the thin snow band, which makes pushing jerky.
        for b in balls where !b.falling && !b.dragging && !b.node.isHidden && b.below == nil {
            guard let p = b.pile, abs(m.x - b.x) < b.r + 8 else { continue }
            if m.y >= p.topY - 6 && m.y <= p.topY + 2 * b.r + 8 { return p }
        }
        if let d = dockPile, mouseOver(d, m) { return d }
        if let dr = dockRect, dr.contains(m) { return nil }
        for item in order {
            if let p = piles[item.id], mouseOver(p, m) { return p }
            if item.rect.contains(m) { return nil }      // over a window's content
        }
        if let g = ground, mouseOver(g, m) { return g }
        return nil
    }

    func updateRolling() {
        let m = NSEvent.mouseLocation     // same coordinates as the scene (origin bottom-left of main screen)
        let dx = m.x - lastMouse.x
        lastMouse = m
        guard let p = surfaceUnderMouse(m) else { activeBall = nil; return }
        guard abs(dx) > 0.2 else { return }

        // Keep rolling the current ball, pick up a resting one under the mouse, or start a new one
        if let b = activeBall, b.pile === p, above(b) == nil, abs(b.x - (m.x - dx)) < b.r + 25 {   // ball was at the previous mouse x
            // keep it
        } else if let b = balls.first(where: { !$0.falling && $0.pile === p && abs($0.x - m.x) < $0.r + 10 }) {
            guard above(b) == nil else { activeBall = nil; return }   // don't roll the bottom of a snowman
            activeBall = b
        } else if let c = p.col(at: m.x), p.h[c] > 1.5 {
            let b = Snowball(body: ballTex!, specks: speckTex!)
            b.x = m.x
            b.pile = p
            b.y = p.topY + b.r - 1.5
            b.layout()
            world.addChild(b.node)
            balls.append(b)
            activeBall = b
            trimBalls()
        } else {
            activeBall = nil
            return
        }
        guard let b = activeBall else { return }

        // Move the ball to the mouse, staying on the surface
        let lo = p.minX + b.r, hi = p.minX + p.width - b.r
        let newX = lo < hi ? min(max(m.x, lo), hi) : b.x
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        let oldX = b.x
        roll(b, on: p, to: newX)
        push(from: b, oldX: oldX, dir: moved > 0 ? 1 : -1, on: p)
    }

    /// Roll a ball to newX: it picks up snow from the columns it passes over and grows
    func roll(_ b: Snowball, on p: Pile, to newX: CGFloat) {
        let moved = newX - b.x
        guard abs(moved) > 0.01 else { return }
        if b.r < Cfg.ballMaxRadius {
            var collected: CGFloat = 0
            let from = min(b.x, newX) - b.r * 0.8
            let to = max(b.x, newX) + b.r * 0.8
            let frac = min(0.6, 0.6 * abs(moved) / (1.6 * b.r))
            if let c0 = p.col(at: max(from, p.minX)), let c1 = p.col(at: min(to, p.minX + p.width - 0.1)), c0 <= c1 {
                for c in c0...c1 where !p.occ[c] {
                    let take = p.h[c] * frac
                    p.h[c] -= take
                    collected += take
                }
                p.dirty = true
            }
            // Ball area grows by the snow area it picked up
            let area = CGFloat.pi * b.r * b.r + collected * Cfg.colW * 0.8
            b.r = min(Cfg.ballMaxRadius, (area / .pi).squareRoot())
        }
        b.x = newX
        b.specks.zRotation -= moved / b.r     // roll
    }

    /// The moving ball pushes any ball it touches in front of it; that ball can push the next one, and so on.
    /// A ball pushed past the end of a surface falls off.
    func push(from b: Snowball, oldX: CGFloat, dir: CGFloat, on p: Pile) {
        // Look for balls ahead of where the pusher *was*: after a fast mouse move it may already have
        // jumped past a ball, and that ball must still be pushed instead of being passed through.
        let ahead = balls
            .filter { $0 !== b && !$0.falling && !$0.dragging && $0.pile === p && ($0.x - oldX) * dir > 0 }
            .sorted { abs($0.x - oldX) < abs($1.x - oldX) }
        var pusher = b
        for o in ahead {
            let need = pusher.x + dir * (pusher.r + o.r)     // where o must be to just touch the pusher
            guard (need - o.x) * dir > 0 else { break }       // not touching: the chain stops here
            let lo = p.minX + o.r, hi = p.minX + p.width - o.r
            if need < lo || need > hi {
                o.x = need
                o.drop(vel: CGVector(dx: dir * 140, dy: 40))  // pushed off the edge
            } else {
                roll(o, on: p, to: need)
            }
            pusher = o
        }
    }

    func trimBalls() {
        while balls.count > Cfg.maxBalls,
              let i = balls.firstIndex(where: { !$0.falling && !$0.dragging && $0.decor == nil && $0 !== activeBall }) {
            balls[i].node.removeFromParent()
            balls.remove(at: i)
        }
    }

    func stepBalls(_ dt: CGFloat) {
        var i = balls.count - 1
        while i >= 0 {
            let b = balls[i]
            var gone = false
            if b.falling {
                if b.decor != nil { b.decor?.removeFromParent(); b.decor = nil }
                b.node.zPosition = 6.5
                let prevBottom = b.y - b.r
                b.vel.dy -= Cfg.gravity * dt
                b.x += b.vel.dx * dt
                b.y += b.vel.dy * dt
                b.specks.zRotation -= b.vel.dx * dt / b.r
                if b.vel.dy < 0, let p = landingSurface(x: b.x, from: prevBottom, to: b.y - b.r) {
                    splat(b, on: p)                  // falling snowballs burst into a heap of snow
                    gone = true
                } else if b.y < -b.r * 2 || b.x < -100 || b.x > size.width + 100 {
                    gone = true
                }
            } else if b.dragging {
                // position is set by stepDrag
            } else if let under = b.below {
                if under.falling || under.dragging {
                    b.drop(vel: CGVector(dx: under.vel.dx + rnd(-40, 40), dy: max(under.vel.dy, 0) + rnd(30, 80)))
                } else {
                    b.x = under.x
                    b.y = under.y + under.r + b.r * 0.82   // sits slightly sunk into the ball below
                    b.node.isHidden = under.node.isHidden
                }
            } else if let p = b.pile {
                if let c = p.col(at: b.x) {
                    b.node.isHidden = p.occ[c]     // hidden behind a window in front
                } else {
                    b.node.isHidden = true
                }
                b.y = p.topY + b.r - 1.5           // sits slightly sunk into the snow
            } else {
                b.drop(vel: .zero)                 // lost its support (e.g. the ball below was removed)
            }
            if gone {
                b.node.removeFromParent()
                balls.remove(at: i)
            } else {
                b.layout()
            }
            i -= 1
        }
    }

    /// First surface a falling ball hits between two heights: the Dock, then window tops (front to back),
    /// then the bottom of the screen. Returns nil if it hits nothing this frame.
    func landingSurface(x: CGFloat, from top: CGFloat, to bottom: CGFloat) -> Pile? {
        func crosses(_ p: Pile) -> Bool {
            guard let c = p.col(at: x), !p.occ[c] else { return false }
            let s = p.surface(c)
            return top >= s && bottom < s
        }
        if let d = dockPile, crosses(d) { return d }
        for item in order {
            if let p = piles[item.id], crosses(p) { return p }
        }
        // The ground catches everything that reaches the bottom, even where a window covers it
        if let g = ground, let c = g.col(at: x), bottom < g.surface(c) { return g }
        return nil
    }

    /// A falling ball bursts where it lands: its snow becomes a mound on that surface, plus a puff of powder
    func splat(_ b: Snowball, on p: Pile) {
        if let c0 = p.col(at: b.x) {
            let snow = CGFloat.pi * b.r * b.r * 0.7 / Cfg.colW     // ball area -> total column height
            let half = max(2, Int(b.r * 1.4 / Cfg.colW))
            var sum: CGFloat = 0
            for o in -half...half { sum += 1 - abs(CGFloat(o)) / CGFloat(half + 1) }
            for o in -half...half {
                let i = c0 + o
                guard i >= 0, i < p.count, !p.occ[i] else { continue }
                let w = (1 - abs(CGFloat(o)) / CGFloat(half + 1)) / sum
                p.h[i] = min(p.caps[i], p.h[i] + snow * w)
            }
            p.dirty = true
        }
        for _ in 0..<min(14, Int(b.r * 0.6) + 2) {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y - b.r * 0.5 + rnd(0, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.2 + rnd(-90, 90), dy: rnd(60, 180)),
                       sourceID: -3)
        }
    }

    /// A falling ball comes to rest on a surface and can be rolled again from there (currently unused)
    func land(_ b: Snowball, on p: Pile) {
        b.falling = false
        b.vel = .zero
        b.pile = p
        let lo = p.minX + b.r, hi = p.minX + p.width - b.r
        if lo < hi { b.x = min(max(b.x, lo), hi) }
        b.y = p.topY + b.r - 1.5
    }

    /// A falling snowball bursts into loose snow when it hits the ground
    func poof(_ b: Snowball) {
        let n = min(40, Int(b.r * 1.6))
        for _ in 0..<n {
            spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y + rnd(-b.r * 0.5, b.r * 0.5)),
                       vel: CGVector(dx: b.vel.dx * 0.3 + rnd(-90, 90), dy: rnd(40, 170)),
                       sourceID: -3)
        }
    }

    // Read all window frames (macOS origin is top-left, SpriteKit is bottom-left, so flip y)
    func pollWindows(dt: CGFloat) {
        let H = size.height
        var newOrder: [(id: Int, rect: CGRect)] = []
        if let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            for w in info {
                guard let layerN = w[kCGWindowLayer as String] as? NSNumber, layerN.intValue == 0,
                      let pidN = w[kCGWindowOwnerPID as String] as? NSNumber, pidN.int32Value != myPID,
                      let numN = w[kCGWindowNumber as String] as? NSNumber,
                      let bd = w[kCGWindowBounds as String] as? NSDictionary,
                      let b = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
                let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
                if alpha < 0.05 || b.width < 80 || b.height < 40 { continue }
                newOrder.append((id: numN.intValue,
                                 rect: CGRect(x: b.minX, y: H - b.maxY, width: b.width, height: b.height)))
            }
        }

        // Closed / minimized windows: their snow just falls
        let alive = Set(newOrder.map { $0.id })
        for (id, pile) in piles where !alive.contains(id) {
            release(pile, vel: .zero, id: id)
            pile.remove()
            piles[id] = nil
            lastRect[id] = nil
        }

        for item in newOrder {
            let id = item.id, r = item.rect
            if let pile = piles[id], let old = lastRect[id] {
                if abs(old.width - r.width) > 0.5 {
                    // Width changed: drop the snow and start a new pile
                    release(pile, vel: .zero, id: id)
                    pile.remove()
                    piles[id] = Pile(minX: r.minX, topY: r.maxY, width: r.width, maxH: Cfg.windowPileMax, parent: world)
                } else if abs(old.minX - r.minX) > 0.3 || abs(old.maxY - r.maxY) > 0.3 {
                    // Window dragged: fling the snow off
                    let v = CGVector(dx: (r.minX - old.minX) / dt, dy: (r.maxY - old.maxY) / dt)
                    pile.minX = r.minX
                    pile.topY = r.maxY
                    release(pile, vel: v, id: id)
                }
            } else {
                piles[id] = Pile(minX: r.minX, topY: r.maxY, width: r.width, maxH: Cfg.windowPileMax, parent: world)
            }
            lastRect[id] = r
        }
        order = newOrder

        // The Dock rarely changes; checking every 0.5 s is enough
        dockAcc += dt
        if dockAcc >= 0.5 {
            dockAcc = 0
            updateDock()
        }

        computeOcclusion()
        for p in piles.values { p.redraw() }
        dockPile?.redraw()
        ground?.redraw()
    }

    func updateDock() {
        var r: CGRect? = nil
        var status: String
        if let f = dockTracker.frame() {
            var s = CGRect(x: f.minX - Cfg.dockPad, y: size.height - f.maxY,
                           width: f.width + 2 * Cfg.dockPad, height: f.height)
            // The AX frame can reach a bit above the visible Dock shelf. When the Dock is always
            // shown, the space macOS reserves for it (bottom of visibleFrame) is a better top edge.
            if let screen = NSScreen.screens.first {
                let reserved = screen.visibleFrame.minY - screen.frame.minY
                if reserved > 10 && reserved < s.maxY { s.size.height = reserved - s.minY }
            }
            // Only handle a Dock that sits at the bottom of the screen and is currently on screen.
            // With auto-hide, a hidden Dock is reported below the screen edge, so it fails this check.
            if s.width > s.height && s.minY < 40 && s.maxY > 8 {
                r = s
                status = "found at x=\(Int(s.minX)) width=\(Int(s.width)) top=\(Int(s.maxY)) (AX top \(Int(size.height - f.minY)), screen \(Int(size.width))x\(Int(size.height)))"
            } else {
                status = "ignored (not at bottom or hidden), AX frame = \(f)"
            }
        } else {
            status = "not found: \(dockTracker.lastError)"
        }
        // Log only when the status changes, so the terminal doesn't get flooded
        let key = status.components(separatedBy: " at ").first ?? status
        if key != lastDockStatus {
            print("❄︎ Dock " + status)
            lastDockStatus = key
        }
        if let old = dockRect, let r = r,
           abs(old.minX - r.minX) < 0.5, abs(old.width - r.width) < 0.5, abs(old.maxY - r.maxY) < 0.5 {
            return
        }
        // Dock resized (new app opened, magnification): drop its snow and start again
        if let p = dockPile {
            release(p, vel: .zero, id: SnowScene.dockID)
            p.remove()
            dockPile = nil
        }
        dockRect = r
        if let r = r {
            dockPile = Pile(minX: r.minX, topY: r.maxY + Cfg.dockTopOffset, width: r.width,
                            maxH: Cfg.dockPileMax, parent: world)
        }
    }

    // Parts of a window top hidden behind a front window get no snow and aren't drawn
    func computeOcclusion() {
        for (i, item) in order.enumerated() {
            guard let p = piles[item.id] else { continue }
            for c in 0..<p.count {
                let pt = CGPoint(x: p.colX(c), y: p.topY + 1)
                var o = pt.x < 0 || pt.x > size.width || pt.y > size.height
                if !o {
                    for j in 0..<i where order[j].rect.contains(pt) { o = true; break }
                }
                if o != p.occ[c] {
                    p.occ[c] = o
                    if o { p.h[c] = 0 }
                    p.dirty = true
                }
            }
        }
        if let g = ground {
            for c in 0..<g.count {
                let pt = CGPoint(x: g.colX(c), y: 1)
                var o = false
                for item in order where item.rect.contains(pt) { o = true; break }
                if o != g.occ[c] {
                    g.occ[c] = o
                    if o { g.h[c] = 0 }
                    g.dirty = true
                }
            }
        }
    }

    func stepFlakes(_ dt: CGFloat) {
        // A few sines at different frequencies add up to gusty wind
        let wind = 14 * sin(t * 0.11) + 9 * sin(t * 0.37 + 1.3) + 6 * sin(t * 0.9 + 0.4)
        var normal = 0
        var i = flakes.count - 1
        while i >= 0 {
            let f = flakes[i]
            var p = f.node.position
            let prevY = p.y

            if f.isClump {
                f.vel.dy -= Cfg.gravity * dt
                f.vel.dx *= max(0, 1 - 1.2 * dt)
                p.x += f.vel.dx * dt
                p.y += f.vel.dy * dt
            } else {
                let sway = sin(t * f.swayFreq + f.phase) * f.swayAmp
                p.x += (wind * f.windFactor + sway) * dt
                p.y += f.vel.dy * dt
                if p.x < -40 { p.x += size.width + 80 } else if p.x > size.width + 40 { p.x -= size.width + 80 }
            }

            var gone = false
            // Snow thrown by the plow is only for show: it never lands, it just falls off the screen
            let plowSpray = f.isClump && f.ignoreID == SnowScene.plowSprayID
            if p.y < prevY && !plowSpray {
                // The Dock is always in front of every window, so check it first
                if let d = dockPile, let c = d.col(at: p.x),
                   !(f.isClump && f.ignoreID == SnowScene.dockID && t < f.ignoreUntil) {
                    let s = d.surface(c)
                    if prevY >= s && p.y < s {
                        d.add(at: c, amount: (f.isClump ? 1.6 : f.size * 0.16) * Cfg.dockGain)
                        gone = true
                    }
                }
                // Then check window tops, front to back
                if !gone && !f.inFront { for item in order {
                    guard let pile = piles[item.id] else { continue }
                    if f.isClump && item.id == f.ignoreID && t < f.ignoreUntil { continue }
                    guard let c = pile.col(at: p.x), !pile.occ[c] else { continue }
                    let s = pile.surface(c)
                    if prevY >= s && p.y < s {
                        pile.add(at: c, amount: f.isClump ? 1.6 : f.size * 0.16)
                        gone = true
                        break
                    }
                } }
                // Finally the bottom of the screen
                if !gone, let g = ground, let c = g.col(at: p.x), p.y < g.surface(c) {
                    if !g.occ[c] { g.add(at: c, amount: f.isClump ? 1.6 : f.size * 0.12) }
                    gone = true
                }
            }
            if !gone {
                // Flakes that fall "behind" a window disappear
                if !f.inFront {
                    for item in order where item.rect.contains(p) { gone = true; break }
                }
                if p.y < -20 { gone = true }
                if f.isClump && (p.x < -80 || p.x > size.width + 80) { gone = true }
            }

            if gone {
                recycle(at: i)
            } else {
                f.node.position = p
                if !f.isClump { normal += 1 }
            }
            i -= 1
        }

        // Top up flakes (max 6 per frame so they don't appear in a row)
        let deficit = min(6, Cfg.targetFlakes - normal)
        if deficit > 0 { for _ in 0..<deficit { spawnFlake() } }
    }
}

// MARK: - Transparent full-screen window + menu bar icon

// MARK: - Snowplow (Option+C): a little truck drives along the bottom and pushes the snow off screen

@MainActor func makePlowTextures() -> (body: SKTexture, wheel: SKTexture) {
    func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    func image(_ w: CGFloat, _ h: CGFloat, _ draw: (CGContext) -> Void) -> SKTexture {
        let scale: CGFloat = 3
        let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        return SKTexture(cgImage: ctx.makeImage()!)
    }
    func vgrad(_ g: CGContext, _ top: CGColor, _ bottom: CGColor, _ y0: CGFloat, _ y1: CGFloat) {
        let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [bottom, top] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(gr, start: CGPoint(x: 0, y: y0), end: CGPoint(x: 0, y: y1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    func rr(_ r: CGRect, _ rad: CGFloat) -> CGPath { CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil) }
    func fill(_ g: CGContext, _ p: CGPath, _ c: CGColor) { g.addPath(p); g.setFillColor(c); g.fillPath() }
    let snow = hex(0xf4f7fd)

    // Truck facing right, 150 x 70 points, wheels are separate sprites so they can turn
    let body = image(150, 70) { g in
        // Exhaust stack behind the cab
        fill(g, rr(CGRect(x: 69, y: 46, width: 3.5, height: 18), 1.2), hex(0x3a3d44))
        fill(g, rr(CGRect(x: 68.3, y: 62, width: 5, height: 2.5), 1), hex(0x5a5d65))
        // Push frame that holds the blade, and the chassis
        fill(g, rr(CGRect(x: 112, y: 10, width: 20, height: 5), 1.5), hex(0x2b2e35))
        fill(g, rr(CGRect(x: 14, y: 11, width: 104, height: 11), 2), hex(0x2b2e35))
        // Dump body in the back (salt and sand), orange with ribs and a reflective stripe
        let dump = rr(CGRect(x: 8, y: 20, width: 60, height: 30), 3)
        g.saveGState(); g.addPath(dump); g.clip()
        vgrad(g, hex(0xffa63e), hex(0xe2700c), 50, 20)
        g.setFillColor(hex(0xb85a08, 0.5))
        for x in stride(from: 18.0, to: 66.0, by: 11.0) { g.fill(CGRect(x: x, y: 29, width: 2, height: 19)) }
        g.setFillColor(hex(0xffffff)); g.fill(CGRect(x: 8, y: 22, width: 60, height: 5))
        g.setFillColor(hex(0xd8262c))
        for x in stride(from: 4.0, to: 70.0, by: 8.0) {
            let s = CGMutablePath(); s.addLines(between: [CGPoint(x: x, y: 22), CGPoint(x: x + 4, y: 22), CGPoint(x: x + 8, y: 27), CGPoint(x: x + 4, y: 27)])
            s.closeSubpath(); g.addPath(s); g.fillPath()
        }
        g.restoreGState()
        // Snow piled on top of the dump body
        fill(g, rr(CGRect(x: 7, y: 48, width: 62, height: 5), 2.5), snow)
        fill(g, rr(CGRect(x: 18, y: 50.5, width: 26, height: 4.5), 2.2), snow)
        // Cab with a sloped windshield
        let cab = CGMutablePath()
        cab.addLines(between: [CGPoint(x: 71, y: 20), CGPoint(x: 114, y: 20), CGPoint(x: 114, y: 38),
                               CGPoint(x: 106, y: 57), CGPoint(x: 74, y: 57), CGPoint(x: 71, y: 54)])
        cab.closeSubpath()
        g.saveGState(); g.addPath(cab); g.clip()
        vgrad(g, hex(0xffae4a), hex(0xe2700c), 57, 20)
        g.restoreGState()
        // Door seam and handle
        g.setStrokeColor(hex(0xa9520a, 0.8)); g.setLineWidth(0.8)
        g.move(to: CGPoint(x: 77, y: 22)); g.addLine(to: CGPoint(x: 77, y: 52)); g.strokePath()
        fill(g, rr(CGRect(x: 80, y: 33, width: 5, height: 1.6), 0.8), hex(0x5a2c05))
        // Window with a reflection
        let win = CGMutablePath()
        win.addLines(between: [CGPoint(x: 80, y: 38), CGPoint(x: 109, y: 38), CGPoint(x: 103.5, y: 52), CGPoint(x: 80, y: 52)])
        win.closeSubpath()
        g.saveGState(); g.addPath(win); g.clip()
        vgrad(g, hex(0xd4ecff), hex(0x5f9bd0), 52, 38)
        let refl = CGMutablePath()
        refl.addLines(between: [CGPoint(x: 92, y: 38), CGPoint(x: 97, y: 38), CGPoint(x: 90, y: 52), CGPoint(x: 85, y: 52)])
        refl.closeSubpath(); g.addPath(refl); g.setFillColor(hex(0xffffff, 0.45)); g.fillPath()
        g.restoreGState()
        // Hood, grille and headlight
        fill(g, rr(CGRect(x: 111, y: 20, width: 11, height: 18), 2.5), hex(0xec7c12))
        g.setFillColor(hex(0x2b2e35))
        for y in stride(from: 22.5, to: 31.0, by: 2.8) { g.fill(CGRect(x: 117.5, y: y, width: 4.5, height: 1.5)) }
        fill(g, CGPath(ellipseIn: CGRect(x: 117.8, y: 32, width: 4.4, height: 4.4), transform: nil), hex(0xfff6c2))
        // Snow on the cab roof, beacon base and amber dome
        fill(g, rr(CGRect(x: 73, y: 55.5, width: 33, height: 3.5), 1.7), snow)
        fill(g, rr(CGRect(x: 86, y: 57.5, width: 9, height: 2.5), 1), hex(0x2b2e35))
        fill(g, rr(CGRect(x: 87.3, y: 59, width: 6.4, height: 6.5), 3), hex(0xffb300))
        // Fenders over the wheels
        fill(g, rr(CGRect(x: 23, y: 19, width: 30, height: 4), 2), hex(0x1f2126))
        fill(g, rr(CGRect(x: 83, y: 19, width: 30, height: 4), 2), hex(0x1f2126))
        // The curved blade at the front, yellow with a black steel cutting edge
        let blade = CGMutablePath()
        blade.move(to: CGPoint(x: 126, y: 3))
        blade.addLine(to: CGPoint(x: 147, y: 1.5))
        blade.addQuadCurve(to: CGPoint(x: 141, y: 33), control: CGPoint(x: 153, y: 17))
        blade.addLine(to: CGPoint(x: 134, y: 34))
        blade.addQuadCurve(to: CGPoint(x: 126, y: 3), control: CGPoint(x: 139, y: 17))
        blade.closeSubpath()
        g.saveGState(); g.addPath(blade); g.clip()
        let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [hex(0xc98f00), hex(0xffd84a), hex(0xf0b400)] as CFArray, locations: [0, 0.55, 1])!
        g.drawLinearGradient(bg, start: CGPoint(x: 127, y: 0), end: CGPoint(x: 150, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        g.setFillColor(hex(0x1b1c20)); g.fill(CGRect(x: 120, y: 0, width: 32, height: 5))
        // Black and yellow warning stripes on the top edge
        g.setFillColor(hex(0x1b1c20, 0.85))
        for y in stride(from: 26.0, to: 36.0, by: 4.0) { g.fill(CGRect(x: 120, y: y, width: 40, height: 1.6)) }
        g.restoreGState()
        // A bit of snow stuck on the blade
        fill(g, rr(CGRect(x: 137, y: 4, width: 9, height: 6), 3), hex(0xffffff, 0.9))
    }

    let wheel = image(24, 24) { g in
        fill(g, CGPath(ellipseIn: CGRect(x: 0.5, y: 0.5, width: 23, height: 23), transform: nil), hex(0x18191d))
        // Tread blocks around the tire, so you can see it turn
        g.setFillColor(hex(0x34363d))
        for i in 0..<10 {
            let a = CGFloat(i) * .pi / 5
            g.fillEllipse(in: CGRect(x: 12 + cos(a) * 10 - 1.3, y: 12 + sin(a) * 10 - 1.3, width: 2.6, height: 2.6))
        }
        fill(g, CGPath(ellipseIn: CGRect(x: 6, y: 6, width: 12, height: 12), transform: nil), hex(0xa9aeb6))
        fill(g, CGPath(ellipseIn: CGRect(x: 9.5, y: 9.5, width: 5, height: 5), transform: nil), hex(0x55585f))
        g.setFillColor(hex(0x2b2e35))
        for i in 0..<5 {
            let a = CGFloat(i) * .pi * 2 / 5
            g.fillEllipse(in: CGRect(x: 12 + cos(a) * 4 - 0.8, y: 12 + sin(a) * 4 - 0.8, width: 1.6, height: 1.6))
        }
    }
    return (body, wheel)
}

@MainActor final class Plow {
    let node = SKNode()
    let truck: SKSpriteNode
    var wheels: [SKSpriteNode] = []
    let dir: CGFloat
    var x: CGFloat
    var speed: CGFloat = 80
    var puffAcc: CGFloat = 0
    static let halfWidth: CGFloat = 75
    static let bladeFront: CGFloat = 72          // truck center -> front of the blade (unscaled points)

    init(tex: (body: SKTexture, wheel: SKTexture), glow: SKTexture, dir: CGFloat, startX: CGFloat) {
        self.dir = dir
        x = startX
        truck = SKSpriteNode(texture: tex.body, size: CGSize(width: 150, height: 70))
        truck.anchorPoint = CGPoint(x: 0.5, y: 0)
        node.addChild(truck)
        for wx in [-37.0, 23.0] as [CGFloat] {
            let w = SKSpriteNode(texture: tex.wheel, size: CGSize(width: 22, height: 22))
            w.position = CGPoint(x: wx, y: 11)
            w.zPosition = 0.05
            node.addChild(w)
            wheels.append(w)
        }
        // Blinking amber beacon on the roof
        let beacon = SKSpriteNode(texture: glow, size: CGSize(width: 30, height: 30))
        beacon.color = NSColor(calibratedRed: 1, green: 0.7, blue: 0.1, alpha: 1)
        beacon.colorBlendFactor = 1
        beacon.blendMode = .add
        beacon.position = CGPoint(x: 15.5, y: 62)
        beacon.zPosition = 0.06
        beacon.run(.repeatForever(.sequence([.fadeAlpha(to: 1, duration: 0.15), .fadeAlpha(to: 0.15, duration: 0.25)])))
        truck.addChild(beacon)
        // Headlight glow
        let lamp = SKSpriteNode(texture: glow, size: CGSize(width: 40, height: 40))
        lamp.color = NSColor(calibratedRed: 1, green: 0.95, blue: 0.7, alpha: 1)
        lamp.colorBlendFactor = 1
        lamp.blendMode = .add
        lamp.alpha = 0.75
        lamp.position = CGPoint(x: 45, y: 34)
        lamp.zPosition = 0.06
        truck.addChild(lamp)
        node.xScale = dir * Cfg.plowScale
        node.yScale = Cfg.plowScale
        node.zPosition = 4.5                     // between the snow's shadow and the snow, so it plows into it
    }

    var blade: CGFloat { x + dir * Plow.bladeFront * Cfg.plowScale }
}

extension SnowScene {
    func callPlow() {
        guard plow == nil, let glow = tex else { return }   // one truck at a time
        if plowTex == nil { plowTex = makePlowTextures() }
        let out = (Plow.halfWidth + 10) * Cfg.plowScale
        let p = Plow(tex: plowTex!, glow: glow, dir: plowDir, startX: plowDir > 0 ? -out : size.width + out)
        world.addChild(p.node)
        plow = p
    }

    func stepPlow(_ dt: CGFloat) {
        guard let p = plow else { return }
        let s = Cfg.plowScale
        let oldBlade = p.blade
        p.speed = min(Cfg.plowSpeed, p.speed + 450 * dt)
        p.x += p.dir * p.speed * dt
        let blade = p.blade

        if let g = ground {
            // Scoop every column the blade passed this frame, plus a little behind it so the snow
            // ahead cannot slump back into the cleared lane
            let lo = min(oldBlade, blade - p.dir * 40), hi = max(oldBlade, blade - p.dir * 40)
            let lo2 = min(lo, blade), hi2 = max(hi, blade)
            let c0 = max(0, Int(((lo2 - g.minX) / Cfg.colW).rounded(.down)))
            let c1 = min(g.count - 1, Int(((hi2 - g.minX) / Cfg.colW).rounded(.down)))
            if c0 <= c1 {
                for c in c0...c1 where g.h[c] > 0 {
                    let amt = g.h[c]
                    // Throw the snow forward off the blade
                    if !g.occ[c] && amt > 0.8 && flakes.count < Cfg.maxClumps + Cfg.targetFlakes {
                        var n = amt / 4
                        while n > 0 {
                            if n < 1 && CGFloat.random(in: 0...1) > n { break }
                            spawnClump(at: CGPoint(x: g.colX(c) + p.dir * rnd(2, 8), y: rnd(2, amt + 4)),
                                       vel: CGVector(dx: p.dir * rnd(140, 320), dy: rnd(60, 240)),
                                       sourceID: SnowScene.plowSprayID)
                            n -= 1
                        }
                    }
                    g.h[c] = 0
                }
                g.dirty = true
            }
            // Snowballs and snowmen in the way burst into spray and are cleared away too
            var hit: [Snowball] = []
            for b in balls where b.pile === g && !b.dragging && !b.falling {
                let back = b.x - p.dir * b.r
                if p.dir * (blade - back) >= 0 && p.dir * (b.x - oldBlade) > -b.r * 2 {
                    for sb in stack(from: base(of: b)) where !hit.contains(where: { $0 === sb }) { hit.append(sb) }
                }
            }
            for b in hit {
                for _ in 0..<min(24, Int(b.r * 1.2) + 4) {
                    spawnClump(at: CGPoint(x: b.x + rnd(-b.r, b.r), y: b.y + rnd(-b.r, b.r)),
                               vel: CGVector(dx: p.dir * rnd(160, 340), dy: rnd(80, 300)),
                               sourceID: SnowScene.plowSprayID)
                }
                b.decor?.removeFromParent()
                b.node.removeFromParent()
                balls.removeAll { $0 === b }
            }
        }

        // Drive: bounce a little on the snow and turn the wheels
        p.node.position = CGPoint(x: p.x, y: 0)
        p.truck.position.y = sin(t * 19) * 0.6
        for w in p.wheels { w.zRotation -= p.speed * dt / 11 }

        // Puffs of exhaust from the stack
        p.puffAcc += dt
        if p.puffAcc > 0.09, let puffTex = tex {
            p.puffAcc = 0
            let puff = SKSpriteNode(texture: puffTex, size: CGSize(width: 7, height: 7))
            puff.color = NSColor(calibratedWhite: 0.55, alpha: 1)
            puff.colorBlendFactor = 1
            puff.alpha = 0.45
            puff.zPosition = 4.4
            puff.position = CGPoint(x: p.x + p.dir * (70.5 - Plow.halfWidth) * s, y: 65 * s)
            world.addChild(puff)
            let life = 1.3
            puff.run(.sequence([.group([.moveBy(x: -p.dir * rnd(25, 45), y: rnd(25, 45), duration: life),
                                        .scale(to: 3.5, duration: life), .fadeOut(withDuration: life)]),
                                .removeFromParent()]))
        }

        // Gone off the other side: next time it comes from this side
        let out = (Plow.halfWidth + 20) * s
        if (p.dir > 0 && p.x > size.width + out) || (p.dir < 0 && p.x < -out) {
            p.node.removeFromParent()
            plow = nil
            plowDir = -p.dir
        }
    }
}

// MARK: - Christmas tree (Option+T): a decorated tree with twinkling lights stands in the snow

/// Tree picture, 170 x 196 points, trunk at the bottom center. Lights and the star are separate sprites so they can twinkle.
@MainActor func makeTreeTexture() -> SKTexture {
    func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    let W: CGFloat = 170, H: CGFloat = 196, scale: CGFloat = 3, cx: CGFloat = 85
    let g = CGContext(data: nil, width: Int(W * scale), height: Int(H * scale), bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    g.scaleBy(x: scale, y: scale)
    var seed: UInt32 = 12345
    func r01() -> CGFloat { seed = seed &* 1664525 &+ 1013904223; return CGFloat(seed >> 8) / CGFloat(1 << 24) }
    func fill(_ p: CGPath, _ c: CGColor) { g.addPath(p); g.setFillColor(c); g.fillPath() }

    // Trunk
    fill(CGPath(roundedRect: CGRect(x: cx - 8, y: 6, width: 16, height: 26), cornerWidth: 2, cornerHeight: 2, transform: nil), hex(0x5a3a22))
    fill(CGPath(rect: CGRect(x: cx - 8, y: 6, width: 5, height: 26), transform: nil), hex(0x452b18))

    // Four tiers of branches, bottom to top: (base y, top y, half width)
    let tiers: [(CGFloat, CGFloat, CGFloat)] = [(24, 98, 66), (62, 132, 53), (98, 162, 40), (130, 188, 27)]
    for (i, (b, t, w)) in tiers.enumerated() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx, y: t))
        path.addLine(to: CGPoint(x: cx + w, y: b))
        // Scalloped bottom edge: little drooping branch tips
        let n = Int(w / 9) + 3
        for k in 0..<n {
            let x0 = cx + w - 2 * w * CGFloat(k) / CGFloat(n)
            let x1 = cx + w - 2 * w * CGFloat(k + 1) / CGFloat(n)
            path.addQuadCurve(to: CGPoint(x: x1, y: b), control: CGPoint(x: (x0 + x1) / 2, y: b - 6))
        }
        path.addLine(to: CGPoint(x: cx, y: t))
        path.closeSubpath()
        g.saveGState()
        g.addPath(path); g.clip()
        // Darker on the left, lit a little on the right
        let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                            colors: [hex(0x0f3a24), hex(0x1d5e38), hex(0x2a7a48)] as CFArray, locations: [0, 0.55, 1])!
        g.drawLinearGradient(gr, start: CGPoint(x: cx - w, y: 0), end: CGPoint(x: cx + w, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // Needle texture: short darker and lighter strokes
        for _ in 0..<Int(w * 2.2) {
            let y = b + r01() * (t - b)
            let half = w * (1 - (y - b) / (t - b))
            let x = cx - half + r01() * 2 * half
            let dir: CGFloat = x < cx ? -1 : 1
            g.setStrokeColor(r01() < 0.5 ? hex(0x0b2e1c, 0.6) : hex(0x3c9a5c, 0.45))
            g.setLineWidth(0.9)
            g.move(to: CGPoint(x: x, y: y)); g.addLine(to: CGPoint(x: x + dir * 4, y: y - 3)); g.strokePath()
        }
        // Shadow under the tier above
        if i > 0 {
            g.setFillColor(hex(0x06200f, 0.35))
            g.fillEllipse(in: CGRect(x: cx - w * 1.1, y: t - 14 - (t - b), width: w * 2.2, height: 10))
        }
        // Snow resting on the branches: along the bottom edge and on the top of each tier
        for k in 0..<Int(w / 4) {
            let x = cx - w + 4 + CGFloat(k) * 8 + r01() * 3
            g.setFillColor(hex(0xf2f6fc, 0.95))
            g.fillEllipse(in: CGRect(x: x - 4, y: b - 1 + r01() * 2.5, width: 8 + r01() * 4, height: 4 + r01() * 2.5))
        }
        for _ in 0..<Int(w / 5) {
            let y = b + (t - b) * (0.25 + r01() * 0.6)
            let half = w * (1 - (y - b) / (t - b))
            let x = cx - half + r01() * 2 * half * 0.7
            g.setFillColor(hex(0xe8eef8, 0.85))
            g.fillEllipse(in: CGRect(x: x, y: y, width: 6 + r01() * 5, height: 2.6 + r01() * 1.6))
        }
        g.restoreGState()
    }

    // Ornaments
    let ornamentColors: [UInt32] = [0xd8283a, 0xe9b43c, 0x2f6fd6, 0xc23ab0, 0xd8283a, 0xf1f1f1]
    var oi = 0
    for (b, t, w) in tiers {
        for _ in 0..<Int(w / 13) + 1 {
            let y = b + 8 + r01() * (t - b) * 0.5
            let half = w * (1 - (y - b) / (t - b)) - 7
            guard half > 2 else { continue }
            let x = cx - half + r01() * 2 * half
            let r: CGFloat = 3.6 + r01() * 1.4
            g.setStrokeColor(hex(0xc9ccd4, 0.8)); g.setLineWidth(0.5)
            g.move(to: CGPoint(x: x, y: y + r)); g.addLine(to: CGPoint(x: x, y: y + r + 3)); g.strokePath()
            let c = ornamentColors[oi % ornamentColors.count]; oi += 1
            let gr = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [hex(0xffffff), hex(c), hex(c, 1)] as CFArray, locations: [0, 0.35, 1])!
            g.saveGState()
            g.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)); g.clip()
            g.setFillColor(hex(c)); g.fill(CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            g.drawRadialGradient(gr, startCenter: CGPoint(x: x + r * 0.35, y: y + r * 0.35), startRadius: 0,
                                 endCenter: CGPoint(x: x, y: y), endRadius: r, options: [])
            g.setFillColor(hex(0x000000, 0.25)); g.fillEllipse(in: CGRect(x: x - r, y: y - r * 1.6, width: 2 * r, height: 1.6 * r))
            g.restoreGState()
            fill(CGPath(rect: CGRect(x: x - 1.2, y: y + r - 0.6, width: 2.4, height: 1.6), transform: nil), hex(0xd9b44a))
        }
    }

    // Presents under the tree
    func gift(_ x: CGFloat, _ w: CGFloat, _ h: CGFloat, _ box: UInt32, _ ribbon: UInt32) {
        fill(CGPath(roundedRect: CGRect(x: x, y: 0, width: w, height: h), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil), hex(box))
        fill(CGPath(rect: CGRect(x: x, y: 0, width: w * 0.3, height: h), transform: nil), hex(0x000000, 0.15))
        fill(CGPath(rect: CGRect(x: x + w / 2 - 1.5, y: 0, width: 3, height: h), transform: nil), hex(ribbon))
        fill(CGPath(rect: CGRect(x: x, y: h / 2 - 1.5, width: w, height: 3), transform: nil), hex(ribbon))
        g.setFillColor(hex(ribbon))
        g.fillEllipse(in: CGRect(x: x + w / 2 - 5, y: h - 1, width: 5, height: 4))
        g.fillEllipse(in: CGRect(x: x + w / 2, y: h - 1, width: 5, height: 4))
        fill(CGPath(rect: CGRect(x: x, y: h - 2, width: w, height: 2), transform: nil), hex(0xffffff, 0.5))
    }
    gift(cx - 54, 22, 17, 0xc8283a, 0xf2d46b)
    gift(cx - 30, 15, 12, 0x2f6fd6, 0xf4f4f4)
    gift(cx + 14, 26, 20, 0x2e8b57, 0xe63a4a)
    gift(cx + 42, 14, 11, 0xe9b43c, 0xc8283a)
    return SKTexture(cgImage: g.makeImage()!)
}

final class ChristmasTree {
    let node = SKNode()
    let tree: SKSpriteNode
    var lights: [SKNode] = []
    let star: SKNode
    var leaving = false
    var gifts: [(node: SKNode, slot: Int)] = []

    init(texture: SKTexture, glowTex: SKTexture?, scale s: CGFloat) {
        node.zPosition = 4.0                     // the plow and the kids pass in front of it
        tree = SKSpriteNode(texture: texture, size: CGSize(width: 170 * s, height: 196 * s))
        tree.anchorPoint = CGPoint(x: 0.5, y: 0)
        node.addChild(tree)

        // Warm glow on the snow around the tree
        let halo = SKSpriteNode(texture: glowTex, size: CGSize(width: 260 * s, height: 70 * s))
        halo.color = nsHex(0xffc27a); halo.colorBlendFactor = 1; halo.blendMode = .add
        halo.alpha = 0.4; halo.position = CGPoint(x: 0, y: 8 * s); halo.zPosition = -0.5
        halo.run(.repeatForever(.sequence([.fadeAlpha(to: 0.3, duration: 1.6), .fadeAlpha(to: 0.45, duration: 1.6)])))
        lights.append(halo)
        node.addChild(halo)

        // Strands of lights wrapped around the tree, sagging across each tier
        let colors: [NSColor] = [nsHex(0xffd27a), nsHex(0xff5a4e), nsHex(0x66e08a), nsHex(0x63a9ff),
                                 nsHex(0xff9ad5), nsHex(0xfff1c9)]
        var ci = Int.random(in: 0..<colors.count)
        // (left end, right end, sag control, bulbs) in tree points from the bottom center
        let strands: [(CGPoint, CGPoint, CGPoint, Int)] = [
            (CGPoint(x: -60, y: 36), CGPoint(x: 52, y: 56), CGPoint(x: -2, y: 26), 10),
            (CGPoint(x: -48, y: 72), CGPoint(x: 40, y: 92), CGPoint(x: -2, y: 64), 8),
            (CGPoint(x: -36, y: 106), CGPoint(x: 30, y: 122), CGPoint(x: -2, y: 98), 6),
            (CGPoint(x: -24, y: 138), CGPoint(x: 18, y: 152), CGPoint(x: -2, y: 132), 5),
            (CGPoint(x: -12, y: 164), CGPoint(x: 8, y: 172), CGPoint(x: -1, y: 160), 3),
        ]
        for (a0, b0, c0, n) in strands {
            let A = CGPoint(x: a0.x * s, y: a0.y * s), B = CGPoint(x: b0.x * s, y: b0.y * s), C = CGPoint(x: c0.x * s, y: c0.y * s)
            let wire = CGMutablePath(); wire.move(to: A); wire.addQuadCurve(to: B, control: C)
            let w = SKShapeNode(path: wire); w.strokeColor = nsHex(0x0d2a19); w.lineWidth = 0.9; w.zPosition = 0.1
            node.addChild(w)
            for i in 0..<n {
                let t = (CGFloat(i) + 0.5) / CGFloat(n)
                let p = CGPoint(x: (1 - t) * (1 - t) * A.x + 2 * (1 - t) * t * C.x + t * t * B.x,
                                y: (1 - t) * (1 - t) * A.y + 2 * (1 - t) * t * C.y + t * t * B.y - 1.2)
                let color = colors[ci % colors.count]; ci += 1
                let holder = SKNode(); holder.position = p; holder.zPosition = 0.2
                let glow = SKSpriteNode(texture: glowTex, size: CGSize(width: 15 * s, height: 15 * s))
                glow.color = color; glow.colorBlendFactor = 1; glow.blendMode = .add
                let low = rnd(0.2, 0.5), slow = Double(rnd(0.5, 1.4))
                glow.run(.sequence([.wait(forDuration: Double(rnd(0, 1.2))),
                                    .repeatForever(.sequence([.fadeAlpha(to: low, duration: slow),
                                                              .fadeAlpha(to: 1, duration: slow * Double(rnd(0.6, 1.2)))]))]))
                holder.addChild(glow)
                let bulb = SKShapeNode(ellipseOf: CGSize(width: 2.8 * s, height: 3.4 * s))
                bulb.fillColor = color; bulb.strokeColor = .clear
                holder.addChild(bulb)
                lights.append(holder)
                node.addChild(holder)
            }
        }

        // Golden star on top with a slow pulsing glow
        let starNode = SKNode(); starNode.position = CGPoint(x: 0, y: 192 * s); starNode.zPosition = 0.4
        let sglow = SKSpriteNode(texture: glowTex, size: CGSize(width: 46 * s, height: 46 * s))
        sglow.color = nsHex(0xffe08a); sglow.colorBlendFactor = 1; sglow.blendMode = .add; sglow.alpha = 0.9
        sglow.run(.repeatForever(.sequence([.group([.fadeAlpha(to: 0.55, duration: 1.2), .scale(to: 0.85, duration: 1.2)]),
                                            .group([.fadeAlpha(to: 1, duration: 1.2), .scale(to: 1.1, duration: 1.2)])])))
        starNode.addChild(sglow)
        let sp = CGMutablePath()
        for k in 0..<10 {
            let r = (k % 2 == 0 ? 10 : 4.2) * s, a = CGFloat.pi / 2 + CGFloat(k) * .pi / 5
            let pt = CGPoint(x: cos(a) * r, y: sin(a) * r)
            if k == 0 { sp.move(to: pt) } else { sp.addLine(to: pt) }
        }
        sp.closeSubpath()
        let shape = SKShapeNode(path: sp)
        shape.fillColor = nsHex(0xffd34d); shape.strokeColor = nsHex(0xd99a1e); shape.lineWidth = 0.8
        starNode.addChild(shape)
        star = starNode
        node.addChild(starNode)
    }
}

extension SnowScene {
    /// Stand next to the Dock on the right, away from where the kids usually play
    func treeX() -> CGFloat {
        let W = size.width
        if let d = dockRect, d.minY < 60, d.maxX > W - 220 { return max(140, d.minX - 130) }
        return W - 150
    }

    func showTree(animated: Bool) {
        guard tree == nil, let glow = tex else { return }
        if treeTex == nil { treeTex = makeTreeTexture() }
        let t = ChristmasTree(texture: treeTex!, glowTex: glow, scale: Cfg.treeScale)
        let x = treeX()
        t.node.position = CGPoint(x: x, y: groundY(x) - 1)
        world.addChild(t.node)
        tree = t
        guard animated else { return }
        // The tree pops up out of the snow, then the lights come on one by one and the star last
        t.node.setScale(0.05)
        t.node.run(.sequence([.scale(to: 1.06, duration: 0.55), .scale(to: 1, duration: 0.15)]))
        t.star.alpha = 0
        for (i, l) in t.lights.enumerated() {
            l.alpha = 0
            l.run(.sequence([.wait(forDuration: 0.7 + 0.06 * Double(i)), .fadeIn(withDuration: 0.25)]))
        }
        t.star.run(.sequence([.wait(forDuration: 0.8 + 0.06 * Double(t.lights.count)), .fadeIn(withDuration: 0.5)]))
    }

    func hideTree() {
        guard let t = tree, !t.leaving else { return }
        t.leaving = true
        tree = nil
        t.star.run(.fadeOut(withDuration: 0.3))
        for (i, l) in t.lights.reversed().enumerated() { l.run(.sequence([.wait(forDuration: 0.03 * Double(i)), .fadeOut(withDuration: 0.2)])) }
        t.node.run(.sequence([.wait(forDuration: 0.03 * Double(t.lights.count) + 0.3),
                              .group([.scale(to: 0.05, duration: 0.45), .fadeOut(withDuration: 0.45)]),
                              .removeFromParent()]))
    }

    /// Keep the tree standing on top of the snow as it piles up or gets plowed
    func stepTree(_ dt: CGFloat) {
        guard let t = tree else { return }
        let x = treeX()
        let target = CGPoint(x: x, y: groundY(x) - 1)
        let k = min(1, dt * 4)
        t.node.position = CGPoint(x: t.node.position.x + (target.x - t.node.position.x) * k,
                                  y: t.node.position.y + (target.y - t.node.position.y) * k)
    }
}

// MARK: - Santa (Option+S): Santa's sleigh, pulled by reindeer, flies across the sky

/// Sleigh with Santa (130 x 90) and a reindeer without legs (80 x 64), both facing right
@MainActor func makeSantaTextures() -> (sleigh: SKTexture, deer: SKTexture) {
    func hex(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
    }
    func image(_ w: CGFloat, _ h: CGFloat, _ draw: (CGContext) -> Void) -> SKTexture {
        let scale: CGFloat = 3
        let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineCap(.round); ctx.setLineJoin(.round)
        draw(ctx)
        return SKTexture(cgImage: ctx.makeImage()!)
    }
    func ell(_ g: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGColor) {
        g.setFillColor(c); g.fillEllipse(in: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h))
    }
    func poly(_ g: CGContext, _ pts: [CGPoint], _ c: CGColor) {
        g.setFillColor(c); g.move(to: pts[0]); for p in pts.dropFirst() { g.addLine(to: p) }; g.closePath(); g.fillPath()
    }
    func line(_ g: CGContext, _ pts: [CGPoint], _ c: CGColor, _ w: CGFloat) {
        g.setStrokeColor(c); g.setLineWidth(w); g.move(to: pts[0]); for p in pts.dropFirst() { g.addLine(to: p) }; g.strokePath()
    }
    let gold = hex(0xf2c14e), goldDark = hex(0xc98f22), red = hex(0xd8343a), redDark = hex(0xa8222c)
    let white = hex(0xf7f7f2), skin = hex(0xf6c9a8)

    let sleigh = image(130, 90) { g in
        // Sack of presents behind Santa
        ell(g, 28, 54, 30, 32, hex(0x7a4a26))
        ell(g, 22, 52, 12, 22, hex(0x63391a))
        poly(g, [CGPoint(x: 24, y: 68), CGPoint(x: 34, y: 68), CGPoint(x: 31, y: 74), CGPoint(x: 27, y: 74)], hex(0x7a4a26))
        line(g, [CGPoint(x: 24, y: 68), CGPoint(x: 34, y: 68)], gold, 2)
        g.setFillColor(hex(0x3aa35c)); g.fill(CGRect(x: 30, y: 42, width: 10, height: 9))
        g.setFillColor(hex(0x3d7be0)); g.fill(CGRect(x: 18, y: 42, width: 10, height: 7))
        line(g, [CGPoint(x: 35, y: 42), CGPoint(x: 35, y: 51)], hex(0xf2d46b), 1.4)
        line(g, [CGPoint(x: 23, y: 42), CGPoint(x: 23, y: 49)], hex(0xf2d46b), 1.4)

        // Santa: coat, belt, beard, face, hat
        ell(g, 66, 50, 26, 30, red)
        ell(g, 60, 50, 10, 26, redDark)
        g.setFillColor(hex(0x2a1d16)); g.fill(CGRect(x: 53, y: 41, width: 26, height: 4))
        g.setFillColor(gold); g.fill(CGRect(x: 66, y: 40.5, width: 5, height: 5))
        ell(g, 70, 62, 20, 20, white)                       // beard
        ell(g, 70, 70, 14, 13, skin)                        // face
        ell(g, 76, 69, 3.2, 3, hex(0xe8907a))               // nose
        line(g, [CGPoint(x: 72, y: 72), CGPoint(x: 74, y: 71.5)], hex(0x3a2a22), 1.1)   // smiling closed eye
        ell(g, 69, 67, 9, 3.5, white)                       // moustache
        ell(g, 76, 65.5, 7, 3.5, white)
        poly(g, [CGPoint(x: 61, y: 75), CGPoint(x: 80, y: 75), CGPoint(x: 66, y: 87), CGPoint(x: 56, y: 82)], red)   // hat
        ell(g, 70, 75.5, 22, 5.5, white)                    // hat brim
        ell(g, 55, 81, 6, 6, white)                         // pompom

        // Sleigh body: tall back on the left, scroll at the front on the right
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 10, y: 22))
        body.addCurve(to: CGPoint(x: 6, y: 60), control1: CGPoint(x: 0, y: 30), control2: CGPoint(x: 0, y: 52))
        body.addQuadCurve(to: CGPoint(x: 24, y: 44), control: CGPoint(x: 18, y: 50))
        body.addLine(to: CGPoint(x: 86, y: 40))
        body.addCurve(to: CGPoint(x: 112, y: 52), control1: CGPoint(x: 96, y: 40), control2: CGPoint(x: 104, y: 54))
        body.addCurve(to: CGPoint(x: 108, y: 34), control1: CGPoint(x: 120, y: 50), control2: CGPoint(x: 118, y: 36))
        body.addCurve(to: CGPoint(x: 92, y: 20), control1: CGPoint(x: 100, y: 30), control2: CGPoint(x: 100, y: 20))
        body.closeSubpath()
        g.addPath(body); g.setFillColor(red); g.fillPath()
        g.saveGState(); g.addPath(body); g.clip()
        g.setFillColor(redDark); g.fill(CGRect(x: 0, y: 20, width: 130, height: 8))
        g.restoreGState()
        // Gold trim along the top edge and around the scroll
        g.setStrokeColor(gold); g.setLineWidth(3)
        g.move(to: CGPoint(x: 6, y: 60)); g.addQuadCurve(to: CGPoint(x: 24, y: 44), control: CGPoint(x: 18, y: 50))
        g.addLine(to: CGPoint(x: 86, y: 40))
        g.addCurve(to: CGPoint(x: 112, y: 52), control1: CGPoint(x: 96, y: 40), control2: CGPoint(x: 104, y: 54))
        g.strokePath()
        g.setStrokeColor(goldDark); g.setLineWidth(2)
        g.addEllipse(in: CGRect(x: 104, y: 40, width: 10, height: 10)); g.strokePath()
        line(g, [CGPoint(x: 18, y: 30), CGPoint(x: 90, y: 28)], gold, 1.4)

        // Runners and struts
        line(g, [CGPoint(x: 28, y: 20), CGPoint(x: 28, y: 9)], gold, 3)
        line(g, [CGPoint(x: 80, y: 20), CGPoint(x: 80, y: 9)], gold, 3)
        g.setStrokeColor(gold); g.setLineWidth(3.4)
        g.move(to: CGPoint(x: 6, y: 9)); g.addLine(to: CGPoint(x: 104, y: 7))
        g.addCurve(to: CGPoint(x: 124, y: 20), control1: CGPoint(x: 116, y: 6), control2: CGPoint(x: 126, y: 10))
        g.addCurve(to: CGPoint(x: 114, y: 22), control1: CGPoint(x: 122, y: 26), control2: CGPoint(x: 114, y: 26))
        g.strokePath()
    }

    let deer = image(80, 64) { g in
        let fur = hex(0xa86b3c), furDark = hex(0x8a5530), cream = hex(0xf3dcb8), antler = hex(0x7a6150)
        // Antlers
        line(g, [CGPoint(x: 60, y: 54), CGPoint(x: 56, y: 61), CGPoint(x: 48, y: 63)], antler, 2.2)
        line(g, [CGPoint(x: 56, y: 61), CGPoint(x: 55, y: 64)], antler, 1.8)
        line(g, [CGPoint(x: 52, y: 62.5), CGPoint(x: 51, y: 64)], antler, 1.6)
        line(g, [CGPoint(x: 63, y: 55), CGPoint(x: 64, y: 61), CGPoint(x: 60, y: 64)], antler, 2.2)
        line(g, [CGPoint(x: 64, y: 61), CGPoint(x: 68, y: 63.5)], antler, 1.6)
        // Tail, body, belly
        ell(g, 12, 33, 8, 7, cream)
        ell(g, 34, 28, 46, 22, fur)
        ell(g, 34, 24, 34, 12, cream)
        ell(g, 22, 30, 14, 14, furDark)
        // Neck and head
        poly(g, [CGPoint(x: 44, y: 34), CGPoint(x: 54, y: 24), CGPoint(x: 66, y: 46), CGPoint(x: 58, y: 54)], fur)
        poly(g, [CGPoint(x: 52, y: 26), CGPoint(x: 58, y: 26), CGPoint(x: 64, y: 42), CGPoint(x: 60, y: 44)], cream)
        ell(g, 64, 50, 15, 12, fur)
        ell(g, 72, 47, 12, 8, fur)                          // snout
        ell(g, 72, 45.5, 9, 4.5, cream)
        poly(g, [CGPoint(x: 57, y: 53), CGPoint(x: 52, y: 58), CGPoint(x: 60, y: 56)], furDark)   // ear
        ell(g, 66.5, 52, 4.4, 4.6, white)                  // eye
        ell(g, 67.3, 52, 2.4, 2.8, hex(0x221a16))
        ell(g, 76.5, 47.5, 4.6, 4.4, hex(0xe0322f))         // nose
        // Harness: red collar with gold bells, and a band around the chest
        line(g, [CGPoint(x: 54, y: 46), CGPoint(x: 62, y: 38)], red, 3)
        for p in [CGPoint(x: 55, y: 43), CGPoint(x: 58, y: 40), CGPoint(x: 61, y: 37.5)] { ell(g, p.x, p.y, 3.6, 3.6, gold) }
        line(g, [CGPoint(x: 42, y: 39), CGPoint(x: 46, y: 18)], red, 3.2)
        line(g, [CGPoint(x: 18, y: 36), CGPoint(x: 52, y: 33)], red, 2.2)
        ell(g, 44, 28, 3.6, 3.6, gold)
    }
    return (sleigh, deer)
}

final class Reindeer {
    let node = SKNode()
    var legs: [(pivot: SKNode, front: Bool)] = []
    let nose = SKSpriteNode()

    init(texture: SKTexture, glowTex: SKTexture?, lead: Bool) {
        let body = SKSpriteNode(texture: texture, size: CGSize(width: 80, height: 64))
        body.zPosition = 0.5
        // Legs hang from the shoulders and hips (texture is centered on the node)
        for (x, front, far) in [(8.0, true, true), (12.0, true, false), (-16.0, false, true), (-11.0, false, false)] as [(CGFloat, Bool, Bool)] {
            let pivot = SKNode()
            pivot.position = CGPoint(x: x, y: -10)
            pivot.zPosition = far ? 0 : 1
            let p = CGMutablePath()
            p.addRoundedRect(in: CGRect(x: -2.6, y: -20, width: 5.2, height: 21), cornerWidth: 2.4, cornerHeight: 2.4)
            let leg = SKShapeNode(path: p)
            leg.fillColor = far ? nsHex(0x7d4b28) : nsHex(0xa86b3c)
            leg.strokeColor = .clear
            let hoof = SKShapeNode(rect: CGRect(x: -2.8, y: -21, width: 5.6, height: 4), cornerRadius: 1.5)
            hoof.fillColor = nsHex(0x3a2a20); hoof.strokeColor = .clear
            leg.addChild(hoof)
            pivot.addChild(leg)
            node.addChild(pivot)
            legs.append((pivot, front))
        }
        node.addChild(body)
        // The lead reindeer's red nose glows
        if lead, let glowTex {
            nose.texture = glowTex
            nose.size = CGSize(width: 18, height: 18)
            nose.color = nsHex(0xff3a30); nose.colorBlendFactor = 1; nose.blendMode = .add
            nose.position = CGPoint(x: 36.5, y: 15.5); nose.zPosition = 0.6
            nose.run(.repeatForever(.sequence([.fadeAlpha(to: 0.5, duration: 0.5), .fadeAlpha(to: 1, duration: 0.5)])))
            node.addChild(nose)
        }
    }

    /// Flying gallop: front legs tuck forward while back legs stretch out, then swap
    func pose(_ phase: CGFloat) {
        for l in legs {
            l.pivot.zRotation = l.front ? 0.9 + 0.55 * sin(phase) : -0.7 + 0.5 * sin(phase + .pi)
        }
    }

    /// Where the reins attach, in the parent's coordinates
    var harness: CGPoint { CGPoint(x: node.position.x + 6, y: node.position.y - 4) }
}

final class SantaSleigh {
    let node = SKNode()
    let sleigh: SKSpriteNode
    let arm = SKNode()
    var deer: [Reindeer] = []
    let reins = SKShapeNode()
    var dir: CGFloat = 1
    var x: CGFloat = 0
    var baseY: CGFloat = 0
    var climb: CGFloat = 0
    var age: CGFloat = 0
    var sparkleAcc: CGFloat = 0
    var giftsLeft = Int.random(in: 2...3)
    var giftTimer = 0
    let deerX: [CGFloat] = [128, 208, 288]
    let deerY: [CGFloat] = [8, 26, 44]

    init(tex: (sleigh: SKTexture, deer: SKTexture), glowTex: SKTexture?) {
        node.zPosition = 3.5
        sleigh = SKSpriteNode(texture: tex.sleigh, size: CGSize(width: 130, height: 90))
        sleigh.zPosition = 1
        // Santa's waving arm, at his shoulder
        arm.position = CGPoint(x: 18, y: 2)
        arm.zPosition = 1.1
        let sleeve = SKShapeNode(rect: CGRect(x: -3.5, y: 0, width: 7, height: 15), cornerRadius: 3)
        sleeve.fillColor = nsHex(0xd8343a); sleeve.strokeColor = .clear
        let cuff = SKShapeNode(rect: CGRect(x: -4, y: 13, width: 8, height: 3.5), cornerRadius: 1.5)
        cuff.fillColor = nsHex(0xf7f7f2); cuff.strokeColor = .clear
        let mitten = SKShapeNode(ellipseOf: CGSize(width: 8, height: 9))
        mitten.position = CGPoint(x: 0, y: 20.5)
        mitten.fillColor = nsHex(0xd8343a); mitten.strokeColor = .clear
        let thumb = SKShapeNode(ellipseOf: CGSize(width: 3.4, height: 4.5))
        thumb.position = CGPoint(x: 4, y: 18.5); thumb.fillColor = nsHex(0xd8343a); thumb.strokeColor = .clear
        for n in [sleeve, cuff, mitten, thumb] { arm.addChild(n) }
        arm.run(.repeatForever(.sequence([.rotate(toAngle: -0.45, duration: 0.35), .rotate(toAngle: 0.2, duration: 0.35)])))
        sleigh.addChild(arm)
        node.addChild(sleigh)
        reins.strokeColor = nsHex(0xc0303a)
        reins.lineWidth = 1.4
        reins.zPosition = 0.8
        node.addChild(reins)
        for i in 0..<3 {
            let d = Reindeer(texture: tex.deer, glowTex: glowTex, lead: i == 2)
            d.node.position = CGPoint(x: deerX[i], y: deerY[i])
            d.node.zPosition = 2 + CGFloat(i) * 0.1
            deer.append(d)
            node.addChild(d.node)
        }
    }
}

extension SnowScene {
    /// Option+S: Santa flies across the sky. One sleigh at a time; each trip goes the other way.
    func callSanta() {
        guard santa == nil else { return }
        if santaTex == nil { santaTex = makeSantaTextures() }
        let s = SantaSleigh(tex: santaTex!, glowTex: tex)
        s.dir = santaDir
        santaDir = -santaDir
        let span = 400 * Cfg.santaScale
        s.x = s.dir > 0 ? -span : size.width + span
        s.baseY = size.height * rnd(0.55, 0.72)
        s.climb = size.height * rnd(0.06, 0.14)
        s.node.setScale(Cfg.santaScale)
        s.node.xScale = s.dir * Cfg.santaScale
        world.addChild(s.node)
        santa = s
        stepSanta(0)
    }

    func stepSanta(_ dt: CGFloat) {
        guard let s = santa, let glow = tex else { return }
        s.age += dt
        s.x += s.dir * Cfg.santaSpeed * dt
        let span = 400 * Cfg.santaScale
        let progress = s.dir > 0 ? (s.x + span) / (size.width + 2 * span) : (size.width + span - s.x) / (size.width + 2 * span)
        let y = s.baseY + s.climb * progress + sin(s.age * 1.3) * 10
        s.node.position = CGPoint(x: s.x, y: y)
        s.node.zRotation = s.dir * 0.05 + cos(s.age * 1.3) * 0.02 * s.dir

        // Sleigh and each reindeer bob on their own beat, and the reins follow
        s.sleigh.position.y = sin(s.age * 4) * 2.5
        let reins = CGMutablePath()
        var from = CGPoint(x: 52, y: s.sleigh.position.y + 6)
        for (i, d) in s.deer.enumerated() {
            let phase = s.age * 9 + CGFloat(i) * 1.1
            d.node.position = CGPoint(x: s.deerX[i], y: s.deerY[i] + sin(phase) * 4)
            d.node.zRotation = sin(phase) * 0.06
            d.pose(phase)
            let to = d.harness
            reins.move(to: from)
            reins.addQuadCurve(to: to, control: CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 8))
            from = CGPoint(x: to.x + 4, y: to.y + 6)
        }
        s.reins.path = reins
        santaDropGifts(s, y: y)

        // Trail of golden sparkles behind the sleigh
        s.sparkleAcc += dt
        while s.sparkleAcc > 0.025 {
            s.sparkleAcc -= 0.025
            let sp = SKSpriteNode(texture: glow, size: CGSize(width: rnd(5, 11), height: rnd(5, 11)))
            sp.color = [nsHex(0xffe08a), nsHex(0xfff6d8), nsHex(0xffc94d)].randomElement()!
            sp.colorBlendFactor = 1
            sp.blendMode = .add
            let back = CGPoint(x: -55 + rnd(-6, 6), y: -30 + s.sleigh.position.y + rnd(-6, 6))
            sp.position = CGPoint(x: s.x + back.x * s.dir * Cfg.santaScale, y: y + back.y * Cfg.santaScale)
            sp.zPosition = 3.4
            world.addChild(sp)
            sp.run(.sequence([.group([.moveBy(x: rnd(-15, 15), y: rnd(-40, -15), duration: 1.4),
                                      .fadeOut(withDuration: 1.4), .scale(to: 0.3, duration: 1.4)]),
                              .removeFromParent()]))
        }

        if (s.dir > 0 && s.x > size.width + span) || (s.dir < 0 && s.x < -span) {
            s.node.removeFromParent()
            santa = nil
        }
    }
}

// MARK: - Presents Santa drops under the Christmas tree

final class FallingGift {
    let node: SKNode
    var vel: CGVector
    var spin: CGFloat
    let slot: Int
    init(node: SKNode, vel: CGVector, slot: Int) {
        self.node = node; self.vel = vel; self.slot = slot
        spin = rnd(-2.5, 2.5)
    }
}

extension SnowScene {
    /// Where presents go, in tree points from the bottom center: in front of the ones already drawn
    static let giftSlots: [CGFloat] = [-70, 68, -36, 30, -2, -90, 90, 50, -54, 12]

    /// A wrapped box with a ribbon and bow, standing on its bottom edge
    func makeGift(scale s: CGFloat) -> SKNode {
        let palette: [(UInt32, UInt32)] = [(0xc8283a, 0xf2d46b), (0x2f6fd6, 0xf4f4f4), (0x2e8b57, 0xe63a4a),
                                           (0xe9b43c, 0xc8283a), (0x8e44ad, 0xf2d46b), (0xf4f4f4, 0xd8283a)]
        let (box, ribbon) = palette.randomElement()!
        let w = rnd(13, 21) * s, h = rnd(10, 16) * s
        let gift = SKNode()
        let body = SKShapeNode(rect: CGRect(x: -w / 2, y: 0, width: w, height: h), cornerRadius: 1.5 * s)
        body.fillColor = nsHex(box); body.strokeColor = .clear
        gift.addChild(body)
        let shade = SKShapeNode(rect: CGRect(x: -w / 2, y: 0, width: w * 0.3, height: h))
        shade.fillColor = NSColor(white: 0, alpha: 0.15); shade.strokeColor = .clear
        gift.addChild(shade)
        for r in [CGRect(x: -1.4 * s, y: 0, width: 2.8 * s, height: h), CGRect(x: -w / 2, y: h / 2 - 1.4 * s, width: w, height: 2.8 * s)] {
            let band = SKShapeNode(rect: r); band.fillColor = nsHex(ribbon); band.strokeColor = .clear
            gift.addChild(band)
        }
        for dx in [-2.6 * s, 2.6 * s] {
            let loop = SKShapeNode(ellipseOf: CGSize(width: 5 * s, height: 4 * s))
            loop.position = CGPoint(x: dx, y: h + 1.2 * s)
            loop.fillColor = nsHex(ribbon); loop.strokeColor = .clear
            gift.addChild(loop)
        }
        return gift
    }

    /// While Santa passes over the tree, he tosses 2 or 3 presents that land in free spots under it
    func santaDropGifts(_ s: SantaSleigh, y: CGFloat) {
        guard let tree = tree, !tree.leaving, s.giftsLeft > 0 else { return }
        s.giftTimer -= 1
        guard s.giftTimer <= 0 else { return }
        let taken = Set(tree.gifts.map { $0.slot } + fallingGifts.map { $0.slot })
        guard let slot = SnowScene.giftSlots.indices.first(where: { !taken.contains($0) }) else { s.giftsLeft = 0; return }
        let ts = Cfg.treeScale
        let land = CGPoint(x: tree.node.position.x + SnowScene.giftSlots[slot] * ts, y: tree.node.position.y)
        // Drop from the sack at the back of the sleigh
        let from = CGPoint(x: s.x - 35 * Cfg.santaScale * s.dir, y: y + 10 * Cfg.santaScale)
        let fall = from.y - land.y
        guard fall > 40 else { return }
        let T = sqrt(2 * fall / SnowScene.giftGravity)
        let dx = land.x - from.x
        // Only let go once the present will glide forward onto its spot, like it was thrown from the sleigh
        guard dx * s.dir > 0, abs(dx) < Cfg.santaSpeed * T * 1.1 else { s.giftTimer = 0; return }
        let gift = makeGift(scale: ts)
        gift.position = from
        gift.zPosition = 4.2
        gift.setScale(0.6)
        gift.run(.scale(to: 1, duration: 0.4))
        world.addChild(gift)
        // Each present twinkles a little while it falls
        if let glow = tex {
            let sp = SKSpriteNode(texture: glow, size: CGSize(width: 22, height: 22))
            sp.color = nsHex(0xffe08a); sp.colorBlendFactor = 1; sp.blendMode = .add; sp.alpha = 0.7
            sp.position = CGPoint(x: 0, y: 8); sp.zPosition = -0.1; sp.name = "giftglow"
            gift.addChild(sp)
        }
        fallingGifts.append(FallingGift(node: gift, vel: CGVector(dx: dx / T, dy: 0), slot: slot))
        s.giftsLeft -= 1
        s.giftTimer = 20                        // frames until the next present
    }

    func stepGifts(_ dt: CGFloat) {
        var i = 0
        while i < fallingGifts.count {
            let f = fallingGifts[i]
            f.vel.dy -= SnowScene.giftGravity * dt
            f.node.position.x += f.vel.dx * dt
            f.node.position.y += f.vel.dy * dt
            f.node.zRotation += f.spin * dt
            let floorY = tree?.node.position.y ?? groundY(f.node.position.x)
            if f.node.position.y <= floorY {
                fallingGifts.remove(at: i)
                f.node.childNode(withName: "giftglow")?.removeFromParent()
                f.node.zRotation = 0
                if let tree = tree, !tree.leaving {
                    // Settle into its spot under the tree with a little bounce; it stays until the tree comes down
                    let ts = Cfg.treeScale
                    f.node.removeFromParent()
                    f.node.position = CGPoint(x: (f.node.position.x - tree.node.position.x) / tree.node.xScale, y: 0)
                    f.node.setScale(1 / ts)
                    f.node.zPosition = 0.3 + CGFloat(f.slot % 3) * 0.01
                    tree.node.addChild(f.node)
                    let spot = CGPoint(x: SnowScene.giftSlots[f.slot], y: 0)
                    f.node.run(.sequence([.group([.move(to: spot, duration: 0.15),
                                                  .sequence([.scaleY(to: 0.8 / ts, duration: 0.08), .scaleY(to: 1 / ts, duration: 0.12)])]),
                                          .moveBy(x: 0, y: 4, duration: 0.1), .moveBy(x: 0, y: -4, duration: 0.1)]))
                    tree.gifts.append((f.node, f.slot))
                } else {
                    // No tree any more: it lands in the snow and fades away
                    f.node.position.y = floorY
                    f.node.run(.sequence([.wait(forDuration: 4), .fadeOut(withDuration: 1), .removeFromParent()]))
                }
                continue
            }
            i += 1
        }
    }
}

// MARK: - Kids and families (Option+P): people come out to play in the snow

func nsHex(_ v: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
            blue: CGFloat(v & 255) / 255, alpha: 1)
}

struct KidLook {
    let coat, hat, scarf, pants, boots, mittens, skin, hair: NSColor
    let pom: NSColor?            // pom-pom on the hat, if any
    let longHair: Bool

    static let skinTones: [UInt32] = [0xffdbac, 0xf1c27d, 0xe0ac69, 0xc68642, 0x8d5524]
    static let hairColors: [UInt32] = [0x2b1b10, 0x5a3825, 0x8b5a2b, 0xd9a441, 0x111111]

    /// Bright winter outfits for kids. Pass `skins` so kids in a family look like their parents.
    static func kids(count: Int, skins: [UInt32]? = nil) -> [KidLook] {
        let outfits: [(coat: UInt32, hat: UInt32, scarf: UInt32)] = [
            (0xe53935, 0x1e3a8a, 0xfdd835), (0x1e88e5, 0xe53935, 0xffffff), (0x43a047, 0xffb300, 0xe53935),
            (0x8e24aa, 0x26c6da, 0xffeb3b), (0xfdd835, 0x1565c0, 0xe91e63), (0xff7043, 0x2e7d32, 0x90caf9),
        ].shuffled()
        let tones = skinTones.shuffled()
        return (0..<count).map { i in
            let o = outfits[i % outfits.count]
            return KidLook(coat: nsHex(o.coat), hat: nsHex(o.hat), scarf: nsHex(o.scarf),
                           pants: nsHex([0x263238, 0x37474f, 0x1a237e, 0x4e342e].randomElement()!),
                           boots: nsHex([0x5d4037, 0x212121, 0xb71c1c, 0x1b5e20].randomElement()!),
                           mittens: nsHex(o.scarf == 0xffffff ? 0xe53935 : o.scarf),
                           skin: nsHex(skins?.randomElement() ?? tones[i % tones.count]),
                           hair: nsHex(hairColors.randomElement()!), pom: nsHex(0xfafafa), longHair: Bool.random())
        }
    }

    /// Two grown-ups in calmer colors; one has long hair and a pom-pom hat
    static func adults(skins: [UInt32]) -> [KidLook] {
        let outfits: [(coat: UInt32, hat: UInt32, scarf: UInt32)] = [
            (0x37474f, 0x8d1b3d, 0xd7ccc8), (0x283593, 0x9e9e9e, 0xc62828), (0x00695c, 0xf5f5f5, 0xffb300),
            (0x6d4c41, 0x1b5e20, 0xeceff1), (0xad1457, 0x37474f, 0xf8bbd0), (0x455a64, 0xc62828, 0xfafafa),
        ].shuffled()
        let longFirst = Bool.random()
        return (0..<2).map { i in
            let o = outfits[i]
            let long = (i == 0) == longFirst
            return KidLook(coat: nsHex(o.coat), hat: nsHex(o.hat), scarf: nsHex(o.scarf),
                           pants: nsHex([0x212121, 0x263238, 0x3e2723].randomElement()!),
                           boots: nsHex([0x3e2723, 0x212121, 0x5d4037].randomElement()!),
                           mittens: nsHex([0x212121, 0x5d4037, o.scarf].randomElement()!),
                           skin: nsHex(skins[i % skins.count]), hair: nsHex(hairColors.randomElement()!),
                           pom: long ? nsHex(o.scarf) : nil, longHair: long)
        }
    }
}

/// A person drawn from simple shapes, seen from the side (facing right; flipped with xScale to face left).
/// Arms and legs are separate nodes that swing from the shoulder and hip. Grown-ups have longer legs,
/// arms and coats, so they are taller without looking like big kids.
@MainActor final class Kid {
    enum Mode { case walk, play, scoop, windup, release, hit, jump, build, wave, pull, ride, gone }
    enum Role { case fighter, builder, jumper, puller, rider }

    let node = SKNode()          // at the feet
    let body = SKNode()          // torso, head and arms; leans and crouches around the hip
    let legF = SKNode(), legB = SKNode(), armF = SKNode(), armB = SKNode()
    let adult: Bool
    let hip: CGFloat             // hip height (unscaled points)
    let scale: CGFloat
    var x: CGFloat
    var facing: CGFloat = 1
    var mode: Mode = .walk
    var afterWalk: Mode = .play
    var role: Role
    weak var opponent: Kid?
    var targetX: CGFloat = 0
    var timer: CGFloat = 0
    var anim = CGFloat.random(in: 0...6)
    var next = CGFloat.random(in: 0.6...1.8)
    var hop: CGFloat = 0, hopV: CGFloat = 0
    var jumpsLeft = 0
    var leaving = false
    var built: [Snowball] = []   // the snowman this person is building, bottom first

    init(look: KidLook, role: Role, x: CGFloat, adult: Bool = false) {
        self.role = role
        self.x = x
        self.adult = adult
        hip = adult ? 29 : 20
        scale = (adult ? 1.15 : 1.0) * Cfg.kidScale
        func part(_ p: CGPath, _ c: NSColor, _ z: CGFloat = 0) -> SKShapeNode {
            let s = SKShapeNode(path: p)
            s.fillColor = c
            s.strokeColor = .clear
            s.lineWidth = 0
            s.zPosition = z
            return s
        }
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
        }
        func circ(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
        }
        func shade(_ c: NSColor) -> NSColor { c.blended(withFraction: 0.25, of: .black) ?? c }
        let H = hip
        let coatBottom: CGFloat = adult ? -10 : -4
        let armLen: CGFloat = adult ? 21 : 15.5

        // Legs hang from the hip; the far one is a little darker
        for (leg, far, z) in [(legB, true, 0.01), (legF, false, 0.03)] as [(SKNode, Bool, CGFloat)] {
            leg.position = CGPoint(x: 0, y: H)
            leg.zPosition = z
            leg.addChild(part(rr(-3.2, -(H - 3), 6.5, H - 2, 3), far ? shade(look.pants) : look.pants))
            leg.addChild(part(rr(-3.5, -(H + 0.5), 9.5, 6, 2.8), far ? shade(look.boots) : look.boots, 0.001))
            node.addChild(leg)
        }
        body.position = CGPoint(x: 0, y: H)
        body.zPosition = 0.02
        node.addChild(body)
        // Puffy coat with a hem and a zipper
        body.addChild(part(rr(-10, coatBottom, 20, 21 - coatBottom, 7.5), look.coat, 0.02))
        body.addChild(part(rr(-10.5, coatBottom - 1, 21, 5, 2.5), shade(look.coat), 0.021))
        let zipPath = CGMutablePath()
        zipPath.move(to: CGPoint(x: 5, y: coatBottom + 4))
        zipPath.addLine(to: CGPoint(x: 5.5, y: 17))
        let zip = SKShapeNode(path: zipPath)
        zip.strokeColor = shade(look.coat)
        zip.lineWidth = 1
        zip.zPosition = 0.022
        body.addChild(zip)
        // Hair at the back (long hair falls to the shoulders), head and a happy face
        body.addChild(part(look.longHair ? rr(-10.5, 13, 9, 18, 4.5) : rr(-9.5, 22, 6, 9, 3), look.hair, 0.03))
        body.addChild(part(circ(0.5, 29, 8.5), look.skin, 0.035))
        for ex in [2.2, 6.2] as [CGFloat] { body.addChild(part(circ(ex, 27.6, 1.05), nsHex(0x2b1b10), 0.04)) }
        body.addChild(part(circ(6.4, 24.8, 1.8), NSColor(calibratedRed: 1, green: 0.45, blue: 0.5, alpha: 0.45), 0.039))
        let smilePath = CGMutablePath()
        smilePath.addArc(center: CGPoint(x: 4.3, y: 25.4), radius: 2, startAngle: .pi * 1.15, endAngle: .pi * 1.85, clockwise: false)
        let smile = SKShapeNode(path: smilePath)
        smile.strokeColor = nsHex(0x7a2e2e)
        smile.lineWidth = 0.9
        smile.lineCap = .round
        smile.zPosition = 0.04
        body.addChild(smile)
        // Beanie, with a pom-pom for some
        let dome = CGMutablePath()
        dome.addArc(center: CGPoint(x: 0.5, y: 31.5), radius: 9.1, startAngle: 0, endAngle: .pi, clockwise: false)
        dome.closeSubpath()
        body.addChild(part(dome, look.hat, 0.05))
        body.addChild(part(rr(-9, 30, 19, 4, 2), shade(look.hat), 0.051))
        if let pom = look.pom { body.addChild(part(circ(0.5, 41.8, 3.3), pom, 0.052)) }
        // Scarf around the neck with a tail hanging in front
        body.addChild(part(rr(4, 8, 5, 12, 2.2), look.scarf, 0.054))
        body.addChild(part(rr(-8.5, 17.5, 18, 5, 2.5), look.scarf, 0.055))
        // Arms swing from the shoulder, with mittens
        for (arm, far, z) in [(armB, true, 0.005), (armF, false, 0.06)] as [(SKNode, Bool, CGFloat)] {
            arm.position = CGPoint(x: -0.5, y: 16)
            arm.zPosition = z
            arm.addChild(part(rr(-2.9, -(armLen - 1.5), 5.8, armLen, 2.9), far ? shade(look.coat) : look.coat))
            arm.addChild(part(circ(0, -armLen, 3.2), far ? shade(look.mittens) : look.mittens, 0.001))
            body.addChild(arm)
        }
        node.zPosition = 5.6       // in front of the snow they stand in, behind snowballs and near flakes
    }
}

/// A wooden sled with red slats, pulled on a rope by a grown-up with a kid riding on it
@MainActor final class Sled {
    let node = SKNode()
    let rope = SKShapeNode()
    weak var puller: Kid?
    weak var rider: Kid?
    var x: CGFloat
    var facing: CGFloat = 1
    static let seat: CGFloat = 11            // seat height (unscaled points)

    init(x: CGFloat) {
        self.x = x
        let runner = CGMutablePath()
        runner.move(to: CGPoint(x: -17, y: 1.5))
        runner.addLine(to: CGPoint(x: 12, y: 1.5))
        runner.addQuadCurve(to: CGPoint(x: 15, y: 9.5), control: CGPoint(x: 20, y: 1.5))
        let r = SKShapeNode(path: runner)
        r.strokeColor = nsHex(0x3e2723)
        r.lineWidth = 2
        r.lineCap = .round
        node.addChild(r)
        let struts = CGMutablePath()
        for sx in [-12.0, -2.0, 8.0] as [CGFloat] {
            struts.move(to: CGPoint(x: sx, y: 1.5))
            struts.addLine(to: CGPoint(x: sx, y: 7))
        }
        let st = SKShapeNode(path: struts)
        st.strokeColor = nsHex(0x8d5524)
        st.lineWidth = 2
        node.addChild(st)
        let seat = SKShapeNode(rect: CGRect(x: -18, y: 6.5, width: 30, height: 4.5), cornerRadius: 2)
        seat.fillColor = nsHex(0xc62828)
        seat.strokeColor = .clear
        node.addChild(seat)
        node.zPosition = 5.58
        rope.strokeColor = nsHex(0xd7ccc8)
        rope.lineWidth = 1.2
        rope.zPosition = 5.57
        node.setScale(Cfg.kidScale)
    }
}

/// A snowball thrown by a kid. If it is aimed at someone it hits them at hitTime, otherwise it lands in the snow.
@MainActor final class KidBall {
    let node: SKSpriteNode
    var vel: CGVector
    weak var target: Kid?
    let aimed: Bool
    let hitTime: CGFloat
    var age: CGFloat = 0
    init(node: SKSpriteNode, vel: CGVector, target: Kid?, hitTime: CGFloat) {
        self.node = node
        self.vel = vel
        self.target = target
        aimed = target != nil
        self.hitTime = hitTime
    }
}

extension SnowScene {
    func groundY(_ x: CGFloat) -> CGFloat {
        guard let g = ground, let c = g.col(at: x) else { return 0 }
        return g.topY + g.h[c] * 0.6           // feet sink into the snow a little
    }

    /// The part of the bottom edge the Dock does not cover
    func playArea() -> (CGFloat, CGFloat) {
        let W = size.width
        if let d = dockRect, d.minY < 60 {
            let left = d.minX, right = W - d.maxX
            if max(left, right) > 240 { return left >= right ? (20, d.minX - 20) : (d.maxX + 20, W - 20) }
            return (40, W - 40)
        }
        // Dock position unknown (no Accessibility permission): it is usually centered, so use the left side
        return (30, max(340, W * 0.3))
    }

    /// Option+P: sometimes a group of kids, sometimes a family. Press again and everyone goes home.
    func callKids() {
        if kids.isEmpty { if Bool.random() { spawnKids() } else { spawnFamily() } }
        else if kids.contains(where: { !$0.leaving }) { sendKidsHome() }
    }

    /// Sets up the play area and returns which side people come from (-1 = left, +1 = right)
    func preparePlay() -> CGFloat {
        let (a, b) = playArea()
        kidsArea = (a, b)
        kidsCenter = (a + b) / 2
        let fromLeft = kidsCenter < size.width / 2
        kidsExit = fromLeft ? -40 : size.width + 40
        kidsClock = 0
        return fromLeft ? -1 : 1
    }

    func addPerson(_ look: KidLook, role: Kid.Role, x: CGFloat, adult: Bool) -> Kid {
        let k = Kid(look: look, role: role, x: x, adult: adult)
        world.addChild(k.node)
        kids.append(k)
        return k
    }

    func spawnKids() {
        let side = preparePlay()
        let n = Int.random(in: 2...3)
        let looks = KidLook.kids(count: n)
        let (a, b) = kidsArea, c = kidsCenter
        // Two kids have a snowball fight; a third one builds a snowman nearer to where they came in
        let d = min(230, (b - a) * 0.45)
        var plan: [(x: CGFloat, role: Kid.Role)] = [(c - d / 2, .fighter), (c + d / 2, .fighter)]
        if n == 3 { plan.append((min(b - 20, max(a + 20, c + side * (d / 2 + 95))), .builder)) }
        plan.sort { abs($0.x - kidsExit) > abs($1.x - kidsExit) }     // the first in line walks the farthest
        var fighters: [Kid] = []
        for (i, p) in plan.enumerated() {
            let k = addPerson(looks[i], role: p.role, x: kidsExit + side * CGFloat(i) * 45, adult: false)
            k.targetX = p.x
            k.afterWalk = p.role == .builder ? .build : .play
            if p.role == .fighter { fighters.append(k) }
        }
        if fighters.count == 2 { fighters[0].opponent = fighters[1]; fighters[1].opponent = fighters[0] }
    }

    /// Two grown-ups and one or two kids. Depending on the family: a parent pulls a kid on a sled,
    /// a parent and a kid have a snowball fight, and/or a parent builds a big snowman.
    func spawnFamily() {
        let side = preparePlay()
        let (a, b) = kidsArea, c = kidsCenter
        let parentSkins = [KidLook.skinTones.randomElement()!, KidLook.skinTones.randomElement()!]
        let parents = KidLook.adults(skins: parentSkins)
        let nKids = Int.random(in: 1...2)
        let children = KidLook.kids(count: nKids, skins: parentSkins)
        let d = min(200, (b - a) * 0.4)
        let farEnd = side < 0 ? b - 30 : a + 30
        let builderX = min(b - 20, max(a + 20, c + side * (d / 2 + 100)))
        let parentLeft = Bool.random()           // which side the parent stands in the snowball fight

        enum Job { case fight, sled, build }
        let jobs: [Job] = nKids == 2 ? [.fight, .sled] : (Bool.random() ? [.sled, .build] : [.fight, .build])

        var order = 0
        func lineX() -> CGFloat { defer { order += 1 }; return kidsExit + side * CGFloat(order) * 50 }
        var parentIndex = 0, childIndex = 0
        func nextParent() -> KidLook { defer { parentIndex += 1 }; return parents[parentIndex] }
        func nextChild() -> KidLook { defer { childIndex += 1 }; return children[childIndex] }

        for job in jobs.sorted(by: { a, _ in a == .sled }) {   // the sled leads the way in
            switch job {
            case .sled:
                let puller = addPerson(nextParent(), role: .puller, x: lineX(), adult: true)
                puller.mode = .pull
                puller.targetX = farEnd
                puller.facing = -side
                let sled = Sled(x: puller.x + side * 34 * Cfg.kidScale)
                let rider = addPerson(nextChild(), role: .rider, x: sled.x, adult: false)
                rider.mode = .ride
                rider.facing = -side
                sled.puller = puller
                sled.rider = rider
                world.addChild(sled.node)
                world.addChild(sled.rope)
                sleds.append(sled)
                order += 1
            case .fight:
                let px = parentLeft ? c - d / 2 : c + d / 2, kx = parentLeft ? c + d / 2 : c - d / 2
                let first = abs(px - kidsExit) > abs(kx - kidsExit)
                let p1 = addPerson(first ? nextParent() : nextChild(), role: .fighter, x: lineX(), adult: first)
                let p2 = addPerson(first ? nextChild() : nextParent(), role: .fighter, x: lineX(), adult: !first)
                p1.targetX = first ? px : kx
                p2.targetX = first ? kx : px
                p1.opponent = p2
                p2.opponent = p1
            case .build:
                let k = addPerson(nextParent(), role: .builder, x: lineX(), adult: true)
                k.targetX = builderX
                k.afterWalk = .build
            }
        }
    }

    func sendKidsHome() {
        for k in kids where !k.leaving {
            k.leaving = true
            k.built = []
            k.mode = .wave
            k.timer = 0
            k.facing = kidsCenter > k.x ? 1 : -1
        }
    }

    func stepKids(_ dt: CGFloat) {
        guard !kids.isEmpty || !kidBalls.isEmpty || !sleds.isEmpty else { return }
        kidsClock += dt
        if kidsClock > Cfg.kidPlayTime { sendKidsHome() }
        stepSleds(dt)
        for k in kids { stepKid(k, dt) }
        kids.removeAll { k in
            guard k.mode == .gone else { return false }
            k.node.removeFromParent()
            return true
        }
        stepKidBalls(dt)
    }

    /// The sled slides along behind the grown-up pulling it, and the kid rides on top
    func stepSleds(_ dt: CGFloat) {
        sleds.removeAll { s in
            guard let p = s.puller, p.mode != .gone, kids.contains(where: { $0 === p }) else {
                s.node.removeFromParent()
                s.rope.removeFromParent()
                return true
            }
            let target = p.x - p.facing * 36 * p.scale
            let d = target - s.x
            if abs(d) > 0.5 { s.x += (d > 0 ? 1 : -1) * min(abs(d), 150 * dt) }
            s.facing = p.facing
            let gy = groundY(s.x)
            s.node.position = CGPoint(x: s.x, y: gy + abs(sin(p.anim * 7)) * 0.8)
            s.node.xScale = s.facing * Cfg.kidScale
            if let r = s.rider, r.mode == .ride {
                r.x = s.x - s.facing * 3 * Cfg.kidScale
                r.facing = s.facing
            }
            // Rope from the hand reaching back to the front of the sled, sagging a little
            let hand = CGPoint(x: p.x - p.facing * 15 * p.scale, y: groundY(p.x) + (p.hip + 4) * p.scale)
            let front = CGPoint(x: s.x + s.facing * 15 * Cfg.kidScale, y: gy + 8 * Cfg.kidScale)
            let path = CGMutablePath()
            path.move(to: hand)
            path.addQuadCurve(to: front, control: CGPoint(x: (hand.x + front.x) / 2, y: min(hand.y, front.y) - 4))
            s.rope.path = path
            return false
        }
    }

    func startJump(_ k: Kid, times: Int = Int.random(in: 1...3)) {
        k.mode = .jump
        k.jumpsLeft = times
        k.timer = 0
    }

    /// Someone who can be hit by a snowball right now (not riding, pulling, building or leaving)
    func canBeTarget(_ k: Kid) -> Bool {
        !k.leaving && k.mode != .ride && k.mode != .pull && k.mode != .build && k.mode != .gone && k.mode != .walk
    }

    func chooseActivity(_ k: Kid) {
        k.timer = 0
        let r = CGFloat.random(in: 0...1)
        switch k.role {
        case .fighter:
            if let o = k.opponent, !o.leaving, r < 0.8 { k.mode = .scoop } else { startJump(k) }
        case .jumper:
            if r < 0.4 {
                startJump(k)                      // jumping to catch snowflakes
            } else if r < 0.75 {
                k.targetX = min(kidsArea.1, max(kidsArea.0, k.x + rnd(-70, 70)))
                k.mode = .walk
                k.afterWalk = .play
            } else if let t = kids.filter({ $0 !== k && canBeTarget($0) }).randomElement() {
                k.opponent = t                    // joins the snowball fight
                k.facing = t.x > k.x ? 1 : -1
                k.mode = .scoop
            } else {
                startJump(k)
            }
        case .builder:
            k.mode = .build
        case .puller:
            k.mode = .pull
        case .rider:
            k.mode = .ride
        }
    }

    func stepKid(_ k: Kid, _ dt: CGFloat) {
        k.timer += dt
        k.anim += dt
        var walking = false
        switch k.mode {
        case .walk:
            let d = k.targetX - k.x
            if abs(d) < 1.5 {
                k.mode = k.afterWalk
                k.timer = 0
                if k.mode == .build { k.facing = kidsCenter >= k.x ? 1 : -1 }
            } else {
                k.facing = d > 0 ? 1 : -1
                k.x += k.facing * min(abs(d), Cfg.kidWalkSpeed * dt)
                walking = true
            }
        case .pull:                               // walk slowly back and forth across the play area
            let d = k.targetX - k.x
            if abs(d) < 1.5 {
                k.targetX = abs(k.x - kidsArea.0) < abs(k.x - kidsArea.1) ? kidsArea.1 - 30 : kidsArea.0 + 30
            } else {
                k.facing = d > 0 ? 1 : -1
                k.x += k.facing * min(abs(d), Cfg.kidWalkSpeed * 0.7 * dt)
                walking = true
            }
        case .ride:
            break                                 // the sled moves this kid
        case .play:
            if k.role == .fighter, let o = k.opponent { k.facing = o.x > k.x ? 1 : -1 }
            if let p = plow, abs(p.x - k.x) < 110 {
                startJump(k, times: 1)            // jump out of the way of the snowplow
            } else {
                k.next -= dt
                if k.next <= 0 { chooseActivity(k) }
            }
        case .scoop:                              // bend down and pack a snowball
            if k.timer > 0.45 { k.mode = .windup; k.timer = 0 }
        case .windup:
            if k.timer > 0.28 { throwSnowball(k); k.mode = .release; k.timer = 0 }
        case .release:
            if k.timer > 0.4 { k.mode = .play; k.timer = 0; k.next = rnd(0.9, 2.4) }
        case .hit:                                // knocked back a little, arms flailing
            if k.timer < 0.25 { k.x -= k.facing * 45 * dt }
            if k.timer > 0.85 { k.mode = .play; k.timer = 0; k.next = rnd(0.3, 1.0) }
        case .jump:
            if k.hop <= 0 && k.hopV <= 0 {
                if k.jumpsLeft > 0 {
                    k.jumpsLeft -= 1
                    k.hopV = rnd(150, 210)
                } else {
                    k.mode = k.leaving ? .wave : .play
                    k.timer = 0
                    k.next = rnd(0.6, 1.8)
                }
            }
        case .build:
            stepBuild(k, dt)
        case .wave:
            if k.timer > 1.1 { k.mode = .walk; k.targetX = kidsExit; k.afterWalk = .gone }
        case .gone:
            break
        }
        if k.hopV != 0 || k.hop > 0 {
            k.hopV -= 650 * dt
            k.hop += k.hopV * dt
            if k.hop <= 0 { k.hop = 0; k.hopV = 0 }
        }
        poseKid(k, walking: walking, dt: dt)
        let y = k.mode == .ride
            ? groundY(k.x) + Sled.seat * Cfg.kidScale - k.hip * k.scale    // sitting on the sled
            : groundY(k.x) + k.hop * k.scale
        k.node.position = CGPoint(x: k.x, y: y)
        k.node.xScale = k.facing * k.scale
        k.node.yScale = k.scale
    }

    /// Arm, leg and body angles for each activity; the limbs ease toward them so moves look smooth
    func poseKid(_ k: Kid, walking: Bool, dt: CGFloat) {
        var lf: CGFloat = 0, lb: CGFloat = 0, af: CGFloat = 0.12, ab: CGFloat = -0.12, lean: CGFloat = 0, dy: CGFloat = 0
        let a = k.anim
        if walking {
            let s = sin(a * (k.adult ? 8.5 : 11))
            lf = s * 0.5; lb = -s * 0.5; af = -s * 0.45; ab = s * 0.45; dy = abs(s) * 1.2
            if k.mode == .pull { af = -0.9; lean = -0.12 }       // arm reaching back to the rope
        } else {
            switch k.mode {
            case .scoop: lf = 0.45; lb = -0.35; af = 0.95; ab = 0.5; lean = -0.35; dy = -3.5
            case .windup: lf = 0.25; lb = -0.25; af = -2.4; ab = 0.7; lean = 0.15
            case .release: lf = 0.35; lb = -0.3; af = 1.7; ab = -0.6; lean = -0.2
            case .hit:
                let w = sin(a * 26) * 0.35
                af = 2.3 + w; ab = -2.3 - w; lean = 0.28; lf = 0.3; lb = -0.2
            case .jump:
                let w = sin(a * 14) * 0.15
                af = 2.9 + w; ab = -2.9 - w
                lf = k.hop > 0 ? 0.6 : 0.2; lb = k.hop > 0 ? -0.4 : -0.2
            case .build:
                let p = sin(a * 12)
                af = 1.25 + p * 0.35; ab = 1.0 - p * 0.35; lf = 0.5; lb = -0.4; lean = -0.3; dy = -4.5
            case .wave: af = 2.7 + sin(a * 11) * 0.4; ab = -0.15
            case .ride:
                // Sitting with legs stretched out, holding on; now and then throws both arms up with joy
                lf = 1.45; lb = 1.3; lean = 0.08
                if sin(a * 0.9) > 0.75 { let w = sin(a * 12) * 0.25; af = 2.7 + w; ab = -2.7 - w }
                else { af = 0.8; ab = 0.6 }
            case .pull: af = -0.9
            default:
                let b = sin(a * 2.2)
                af = 0.12 + b * 0.05; ab = -0.12 - b * 0.05; dy = b * 0.4
            }
        }
        let f = min(1, dt * 16)
        func ease(_ n: SKNode, _ v: CGFloat) { n.zRotation += (v - n.zRotation) * f }
        ease(k.legF, lf); ease(k.legB, lb); ease(k.armF, af); ease(k.armB, ab); ease(k.body, lean)
        k.body.position.y += (k.hip + dy - k.body.position.y) * f
    }

    func throwSnowball(_ k: Kid) {
        guard let o = k.opponent, let bt = ballTex else { return }
        let s = k.scale
        let start = CGPoint(x: k.x + k.facing * 8 * s, y: groundY(k.x) + k.hop * s + (k.hip + 26) * s)
        let dir: CGFloat = o.x > k.x ? 1 : -1
        let willHit = canBeTarget(o) && CGFloat.random(in: 0...1) < 0.6
        let aim: CGPoint
        if willHit {
            aim = CGPoint(x: o.x, y: groundY(o.x) + (o.hip + 16) * o.scale)
        } else {
            // Misses: lands in the snow just short of or behind the other person
            let mx = o.x + dir * (Bool.random() ? rnd(22, 60) : -rnd(25, 60))
            aim = CGPoint(x: mx, y: groundY(mx))
        }
        let T = min(0.95, max(0.45, abs(aim.x - start.x) / 300))
        let g: CGFloat = 600
        let v = CGVector(dx: (aim.x - start.x) / T, dy: (aim.y - start.y + 0.5 * g * T * T) / T)
        let node = SKSpriteNode(texture: bt, size: CGSize(width: 9 * s, height: 9 * s))
        node.position = start
        node.zPosition = 6.6
        world.addChild(node)
        kidBalls.append(KidBall(node: node, vel: v, target: willHit ? o : nil, hitTime: T))
    }

    func stepKidBalls(_ dt: CGFloat) {
        var i = kidBalls.count - 1
        while i >= 0 {
            let b = kidBalls[i]
            b.age += dt
            b.vel.dy -= 600 * dt
            var p = b.node.position
            p.x += b.vel.dx * dt
            p.y += b.vel.dy * dt
            b.node.position = p
            b.node.zRotation -= 8 * dt
            var burst = false
            if b.aimed && b.age >= b.hitTime {
                burst = true
                if let t = b.target, canBeTarget(t) {
                    t.mode = .hit
                    t.timer = 0
                    t.facing = b.vel.dx > 0 ? -1 : 1          // turns toward the thrower
                }
            } else if !b.aimed && b.vel.dy < 0 && p.y <= groundY(p.x) + 2 {
                burst = true
            } else if p.x < -50 || p.x > size.width + 50 || p.y < -20 {
                b.node.removeFromParent()
                kidBalls.remove(at: i)
                i -= 1
                continue
            }
            if burst {
                // Poof! The spray is only for show and does not add snow anywhere
                for _ in 0..<12 {
                    spawnClump(at: CGPoint(x: p.x + rnd(-3, 3), y: p.y + rnd(-3, 3)),
                               vel: CGVector(dx: b.vel.dx * 0.12 + rnd(-90, 90), dy: rnd(40, 190)),
                               sourceID: SnowScene.plowSprayID)
                }
                b.node.removeFromParent()
                kidBalls.remove(at: i)
            }
            i -= 1
        }
    }

    /// The builder pats a snowman together from three real snowballs, so it stays after they leave.
    /// Grown-ups build a bigger one.
    func stepBuild(_ k: Kid, _ dt: CGFloat) {
        guard let bt = ballTex, let st = speckTex, let g = ground else { return }
        // Someone grabbed or knocked one of the balls: give up and go play instead
        if k.built.contains(where: { b in b.falling || b.dragging || !balls.contains { $0 === b } }) {
            k.built = []
            k.role = .jumper
            k.mode = .play
            k.next = 0.5
            return
        }
        let sizes: [CGFloat] = [15, 11, 8].map { $0 * k.scale * (k.adult ? 1.15 : 1) }
        let stage = k.built.count - 1
        if stage < 0 || (stage < 2 && k.built[stage].r >= sizes[stage]) {
            let b = Snowball(body: bt, specks: st)
            b.r = 3
            if let below = k.built.last {
                b.below = below
                b.x = below.x
                b.y = below.y + below.r + b.r * 0.82
            } else {
                b.x = k.x + k.facing * (k.adult ? 32 : 26) * k.scale
                b.pile = g
                b.y = g.topY + b.r - 1.5
            }
            b.layout()
            world.addChild(b.node)
            balls.append(b)
            k.built.append(b)
            trimBalls()
            return
        }
        let b = k.built[stage]
        if b.r < sizes[stage] {
            b.r = min(sizes[stage], b.r + dt * (sizes[stage] - 2) / 2.2)
            b.specks.zRotation -= dt * 3
        } else {
            makeSnowman(k.built)                  // all three done: face, scarf and stick arms
            k.built = []
            k.role = .jumper
            startJump(k, times: 2)                // a happy jump
        }
    }
}

/// Lets the very first click reach the scene even though this app is never the active app
final class OverlaySKView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayWindow: NSPanel {
    // Stop macOS from pushing the window below the menu bar
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: OverlayWindow!
    var scene: SnowScene!
    var statusItem: NSStatusItem!
    var pauseItem: NSMenuItem!
    var lightsItem: NSMenuItem!
    var treeItem: NSMenuItem!
    var amountItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NSScreen.screens.first else { return }
        // A non-activating panel can take a click (to grab a snowball) without stealing focus from your apps
        window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true          // clicks pass straight through
        window.level = .floating                  // above normal windows, below the Dock and menu bar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = OverlaySKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.allowsTransparency = true
        view.preferredFramesPerSecond = 60
        view.ignoresSiblingOrder = true
        scene = SnowScene(size: screen.frame.size)
        scene.scaleMode = .resizeFill
        view.presentScene(scene)
        window.contentView = view
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()

        setupMenu()
        registerPlowHotKey()
        // The tree stays up between launches until you take it down
        if UserDefaults.standard.bool(forKey: "christmasTree") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.setTree(true, animated: true) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Stop rendering while the display sleeps or the screen is locked; otherwise SpriteKit
        // logs "no drawables available" because nothing is being shown.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            ws.addObserver(self, selector: #selector(suspendRendering), name: name, object: nil)
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(self, selector: #selector(resumeRendering), name: name, object: nil)
        }
    }

    /// True only when the user chose "Pause Snow". Kept separate from scene.isPaused, because
    /// pausing the SKView for sleep also sets scene.isPaused, which used to make the snow
    /// look user-paused after waking, so it stayed frozen forever.
    var userPaused = false

    @objc func suspendRendering() {
        (window.contentView as? SKView)?.isPaused = true
    }

    @objc func resumeRendering() {
        // Stay paused if the user paused snow from the menu
        guard !userPaused else { return }
        // Wake can fire before the display is ready to draw, so resume now and again shortly after
        for delay in [0.0, 1.0, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.userPaused else { return }
                if let screen = NSScreen.screens.first { self.window.setFrame(screen.frame, display: true) }
                (self.window.contentView as? SKView)?.isPaused = false
                self.scene.isPaused = false
                self.window.orderFrontRegardless()
            }
        }
    }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "❄︎"
        let menu = NSMenu()

        pauseItem = NSMenuItem(title: "Pause Snow", action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let amount = NSMenuItem(title: "Snow Amount", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, n) in [("Light", 120), ("Medium", 260), ("Heavy", 500)] {
            let it = NSMenuItem(title: title, action: #selector(setAmount(_:)), keyEquivalent: "")
            it.target = self
            it.tag = n
            it.state = (n == Cfg.targetFlakes) ? .on : .off
            sub.addItem(it)
            amountItems.append(it)
        }
        amount.submenu = sub
        menu.addItem(amount)

        let clear = NSMenuItem(title: "Clear Snow", action: #selector(clearSnow), keyEquivalent: "c")
        clear.target = self
        menu.addItem(clear)

        let plowItem = NSMenuItem(title: "Call Snowplow", action: #selector(callPlow), keyEquivalent: "c")
        plowItem.keyEquivalentModifierMask = [.option]
        plowItem.target = self
        menu.addItem(plowItem)

        lightsItem = NSMenuItem(title: "Snowman Lights", action: #selector(toggleLights), keyEquivalent: "")
        lightsItem.target = self
        lightsItem.state = Cfg.snowmanLights ? .on : .off
        menu.addItem(lightsItem)

        let kidsItem = NSMenuItem(title: "Kids or Family Come Out to Play", action: #selector(callKids), keyEquivalent: "p")
        kidsItem.keyEquivalentModifierMask = [.option]
        kidsItem.target = self
        menu.addItem(kidsItem)

        treeItem = NSMenuItem(title: "Christmas Tree", action: #selector(toggleTree), keyEquivalent: "t")
        treeItem.keyEquivalentModifierMask = [.option]
        treeItem.target = self
        menu.addItem(treeItem)

        let santaItem = NSMenuItem(title: "Santa Flies By", action: #selector(callSanta), keyEquivalent: "s")
        santaItem.keyEquivalentModifierMask = [.option]
        santaItem.target = self
        menu.addItem(santaItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc func togglePause() {
        userPaused.toggle()
        scene.isPaused = userPaused
        (window.contentView as? SKView)?.isPaused = userPaused
        if userPaused {
            window.orderOut(nil)
            pauseItem.title = "Resume Snow"
        } else {
            window.orderFrontRegardless()
            pauseItem.title = "Pause Snow"
        }
    }

    @objc func setAmount(_ sender: NSMenuItem) {
        Cfg.targetFlakes = sender.tag
        for it in amountItems { it.state = (it === sender) ? .on : .off }
    }

    @objc func clearSnow() { scene.clearAll() }

    @objc func toggleLights() {
        scene.setSnowmanLights(!Cfg.snowmanLights)
        lightsItem.state = Cfg.snowmanLights ? .on : .off
    }

    @objc func callPlow() {
        guard !userPaused else { return }
        scene.callPlow()
    }

    /// Option+P: kids or a family come out to play; press again and they wave and go home
    @objc func callKids() {
        guard !userPaused else { return }
        scene.callKids()
    }

    /// Option+T: put up the Christmas tree, or take it down
    @objc func toggleTree() {
        guard !userPaused else { return }
        setTree(scene.tree == nil, animated: true)
    }

    func setTree(_ on: Bool, animated: Bool) {
        if on { scene.showTree(animated: animated) } else { scene.hideTree() }
        treeItem.state = on ? .on : .off
        UserDefaults.standard.set(on, forKey: "christmasTree")
    }

    var plowHotKey: EventHotKeyRef?
    var treeHotKey: EventHotKeyRef?
    var santaHotKey: EventHotKeyRef?

    /// Option+S: Santa's sleigh flies across the sky
    @objc func callSanta() {
        guard !userPaused else { return }
        scene.callSanta()
    }
    var kidsHotKey: EventHotKeyRef?

    /// Option+C anywhere calls the snowplow. A Carbon hot key works without any extra permission.
    func registerPlowHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let which = key.id
            DispatchQueue.main.async {
                guard let d = NSApp.delegate as? AppDelegate else { return }
                if which == 1 { d.callPlow() } else if which == 2 { d.callKids() } else if which == 3 { d.toggleTree() } else if which == 4 { d.callSanta() }
            }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x534E4F57), id: 1)   // 'SNOW'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(optionKey), id,
                                         GetApplicationEventTarget(), 0, &plowHotKey)
        if status != noErr { print("❄︎ Could not register Option+C for the snowplow (another app may use it)") }
        let kidsID = EventHotKeyID(signature: OSType(0x534E4F57), id: 2)
        let kidsStatus = RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(optionKey), kidsID,
                                             GetApplicationEventTarget(), 0, &kidsHotKey)
        if kidsStatus != noErr { print("❄︎ Could not register Option+P for the kids (another app may use it)") }
        let treeID = EventHotKeyID(signature: OSType(0x534E4F57), id: 3)
        let treeStatus = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(optionKey), treeID,
                                             GetApplicationEventTarget(), 0, &treeHotKey)
        if treeStatus != noErr { print("❄︎ Could not register Option+T for the Christmas tree (another app may use it)") }
        let santaID = EventHotKeyID(signature: OSType(0x534E4F57), id: 4)
        let santaStatus = RegisterEventHotKey(UInt32(kVK_ANSI_S), UInt32(optionKey), santaID,
                                              GetApplicationEventTarget(), 0, &santaHotKey)
        if santaStatus != noErr { print("❄︎ Could not register Option+S for Santa (another app may use it)") }
    }

    @objc func screensChanged() {
        guard let screen = NSScreen.screens.first else { return }
        window.setFrame(screen.frame, display: true)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // no Dock icon
app.run()
