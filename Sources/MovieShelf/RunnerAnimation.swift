import AppKit
import QuartzCore

/// 加载小人的墨色：纸白卡片上的近黑笔触，远近肢体靠透明度拉开层次。
struct RunnerPalette {
    var ink: NSColor
    var farInk: NSColor
    var shadow: NSColor
    var speed: NSColor
    /// 近端手臂（人物右侧）与远端手臂（人物左侧）
    var rightArm: NSColor
    var leftArm: NSColor

    static let paper = RunnerPalette(
        ink: NSColor(calibratedWhite: 0.055, alpha: 1),
        farInk: NSColor(calibratedWhite: 0.055, alpha: 0.30),
        shadow: NSColor(calibratedWhite: 0.0, alpha: 1),
        speed: NSColor(calibratedWhite: 0.055, alpha: 1),
        rightArm: NSColor(srgbRed: 0.88, green: 0.18, blue: 0.21, alpha: 1),
        leftArm: NSColor(srgbRed: 0.16, green: 0.66, blue: 0.32, alpha: 1)
    )
}

/// 纯 CoreGraphics 绘制的小人：给定 0...1 的步态相位，画出一帧侧面奔跑姿态。
///
/// 造型：圆头 Q 版——头大、四肢短粗，躯干是一整块圆润的形体（没有单独鼓出的肚子）。
/// 动作：四段关键姿态（触地 / 支撑 / 蹬离 / 摆动）做周期性三次插值；
/// 髋高由支撑脚反推，脚掌始终踩实地面；手肘在后摆时接近伸直、前摆时收到 90°。
enum RunnerFigure {
    // MARK: 对外

    static func draw(in ctx: CGContext, rect: CGRect, phase: Double,
                     palette: RunnerPalette = .paper) {
        let box = rect.height
        let H = box * 0.79
        guard H > 24, rect.width > 48 else { return }

        let groundY = rect.minY + box * 0.92
        let sway = 0.005 * H * CGFloat(sin(2 * .pi * phase + 0.7))
        let hipX = rect.midX + rect.width * 0.02 + sway

        // 比例（相对小人高度 H）：圆头、短粗四肢、圆润上身
        let headR = 0.150 * H
        let thigh = 0.235 * H
        let shin = 0.235 * H
        let upperArm = 0.152 * H
        let foreArm = 0.142 * H
        let limbW = 0.105 * H
        let armW = 0.098 * H
        let bodyWidth = 0.215 * H
        let bodyLen = 0.250 * H

        let hipLift = hipHeight(phase: phase, thigh: thigh, shin: shin, toeOff: 0.30)
        let hip = CGPoint(x: hipX, y: groundY - hipLift)

        let lean = 0.075 * H
        let shoulder = CGPoint(x: hip.x + lean, y: hip.y - bodyLen)
        let headCenter = CGPoint(x: shoulder.x + 0.016 * H,
                                 y: shoulder.y - (headR + 0.020 * H))

        let nearLeg = leg(phase: phase, hip: hip, thigh: thigh, shin: shin)
        let farLeg = leg(phase: phase + 0.5, hip: hip, thigh: thigh, shin: shin)
        let armRoot = CGPoint(x: shoulder.x + 0.012 * H, y: shoulder.y + 0.010 * H)
        let nearArm = arm(phase: phase + 0.5, root: armRoot, upper: upperArm, fore: foreArm)
        let farArm = arm(phase: phase + 1.0, root: armRoot, upper: upperArm, fore: foreArm)

        let clearance = min(nearLeg.foot.y, farLeg.foot.y) - groundY
        let air = min(1, max(0, clearance / (0.18 * H)))

        drawSpeedLines(ctx, hipX: hipX, groundY: groundY, H: H, phase: phase)
        drawShadow(ctx, hipX: hipX, groundY: groundY, H: H, air: air, palette: palette)

        // 远端手臂 + 远端腿（淡墨，先画）
        stroke(ctx, [armRoot, farArm.elbow, farArm.hand],
               width: armW, color: palette.leftArm.cgColor)
        stroke(ctx, [hip, farLeg.knee, farLeg.foot],
               width: limbW, color: palette.ink.cgColor)

        // 近端腿
        stroke(ctx, [hip, nearLeg.knee, nearLeg.foot],
               width: limbW, color: palette.ink.cgColor)

        // 躯干：一整块圆润的形体
        drawBody(ctx, hip: hip, shoulder: shoulder, H: H,
                 width: bodyWidth, hipDrop: 0.05, color: palette.ink.cgColor)

        // 脖子
        stroke(ctx, [shoulder, headCenter], width: 0.070 * H, color: palette.ink.cgColor)

        // 近端手臂：外面留一圈纸色描边，压在黑色躯干上也能看出是“手臂”
        stroke(ctx, [armRoot, nearArm.elbow, nearArm.hand],
               width: armW + 0.022 * H, color: NSColor(calibratedRed: 0.997, green: 0.994, blue: 0.988, alpha: 1).cgColor)
        stroke(ctx, [armRoot, nearArm.elbow, nearArm.hand],
               width: armW, color: palette.rightArm.cgColor)

        // 头
        ctx.setFillColor(palette.ink.cgColor)
        ctx.fillEllipse(in: CGRect(x: headCenter.x - headR, y: headCenter.y - headR,
                                   width: headR * 2, height: headR * 2))
    }

    /// 节奏：前 1.4 秒从 1.15 Hz 缓上到 1.95 Hz，之后匀速；相位带一点起始偏置。
    static func phase(at time: Double) -> Double {
        let ramp = 1.4
        let low = 1.15
        let high = 1.95
        let cycles: Double
        if time < ramp {
            cycles = low * time + (high - low) * time * time / (2 * ramp)
        } else {
            cycles = low * ramp + (high - low) * ramp / 2 + high * (time - ramp)
        }
        return (cycles + 0.10).truncatingRemainder(dividingBy: 1)
    }

    // MARK: 步态关键帧（相位 0 = 近端脚触地）

    private static let thighKeys: [(t: Double, v: Double)] = [
        (0.00, 28), (0.25, 0), (0.50, -32), (0.75, -2)
    ]
    private static let kneeKeys: [(t: Double, v: Double)] = [
        (0.00, 8), (0.25, 18), (0.50, 28), (0.75, 68)
    ]

    /// 髋高由支撑脚的长度反推：脚踩在地上，身体自然跟着起伏。
    /// 腾空段用一段小抛物线过渡到下一次落地。
    private static func hipHeight(phase: Double, thigh: CGFloat, shin: CGFloat,
                                  toeOff: Double) -> CGFloat {
        func depth(_ ph: Double) -> CGFloat {
            let th = curve(thighKeys, ph) * .pi / 180
            let kn = curve(kneeKeys, ph) * .pi / 180
            return thigh * cos(th) + shin * cos(th - kn)
        }
        let pN = wrap(phase)
        let pF = wrap(phase + 0.5)
        if pN < toeOff { return depth(pN) }
        if pF < toeOff { return depth(pF) }
        let start = depth(toeOff)
        let end = depth(0)
        let u: CGFloat = pN < 0.5
            ? CGFloat((pN - toeOff) / (0.5 - toeOff))
            : CGFloat((pN - 0.8) / 0.2)
        return start + (end - start) * u + 0.020 * (thigh + shin) * sin(.pi * u)
    }

    private static func leg(phase: Double, hip: CGPoint,
                            thigh: CGFloat, shin: CGFloat)
        -> (knee: CGPoint, foot: CGPoint)
    {
        let p = wrap(phase)
        let th = curve(thighKeys, p) * .pi / 180
        let kn = curve(kneeKeys, p) * .pi / 180
        let knee = CGPoint(x: hip.x + thigh * sin(th),
                           y: hip.y + thigh * cos(th))
        let foot = CGPoint(x: knee.x + shin * sin(th - kn),
                           y: knee.y + shin * cos(th - kn))
        return (knee, foot)
    }

    /// 手臂：上臂整体前后摆；后摆时手肘几乎伸直，前摆时收成约 90°，读起来像“甩臂”。
    private static func arm(phase: Double, root: CGPoint,
                            upper: CGFloat, fore: CGFloat)
        -> (elbow: CGPoint, hand: CGPoint)
    {
        let t = 2 * Double.pi * wrap(phase)
        let swing = (-55 * cos(t)) * .pi / 180
        let flex = (55 - 45 * cos(t)) * .pi / 180
        let elbow = CGPoint(x: root.x + upper * sin(swing),
                            y: root.y + upper * cos(swing))
        let hand = CGPoint(x: elbow.x + fore * sin(swing + flex),
                           y: elbow.y + fore * cos(swing + flex))
        return (elbow, hand)
    }

    /// 周期性三次插值（Catmull-Rom 切线），首尾相接。
    private static func curve(_ keys: [(t: Double, v: Double)], _ phase: Double) -> CGFloat {
        let p = wrap(phase)
        let n = keys.count
        var i = 0
        while i < n - 1 && p >= keys[i + 1].t { i += 1 }
        let k0 = keys[i]
        let k1 = keys[(i + 1) % n]
        let kPrev = keys[(i - 1 + n) % n]
        let kNext = keys[(i + 2) % n]

        let t0 = i == n - 1 ? k0.t - 1 : k0.t
        let t1 = k1.t
        let dt = max(0.0001, t1 - t0)

        let prevT = i == 0 ? kPrev.t - 1 : kPrev.t
        let nextT = i + 2 >= n ? kNext.t + 1 : kNext.t
        let m0 = (k1.v - kPrev.v) / max(0.0001, t1 - prevT)
        let m1 = (kNext.v - k0.v) / max(0.0001, nextT - t0)

        let u = min(1, max(0, (p - t0) / dt))
        let u2 = u * u
        let u3 = u2 * u
        let h00 = 2 * u3 - 3 * u2 + 1
        let h10 = u3 - 2 * u2 + u
        let h01 = -2 * u3 + 3 * u2
        let h11 = u3 - u2
        return CGFloat(h00 * k0.v + h10 * dt * m0 + h01 * k1.v + h11 * dt * m1)
    }

    private static func wrap(_ p: Double) -> Double {
        let v = p.truncatingRemainder(dividingBy: 1)
        return v < 0 ? v + 1 : v
    }

    // MARK: 形体

    /// 圆润的躯干：沿“髋 → 肩”采样一圈闭合轮廓，上端稍窄、下端略宽，端头用半圆封口。
    private static func drawBody(_ ctx: CGContext, hip: CGPoint, shoulder: CGPoint,
                                 H: CGFloat, width: CGFloat, hipDrop: CGFloat,
                                 color: CGColor)
    {
        let dx = shoulder.x - hip.x
        let dy = shoulder.y - hip.y
        let len = max(0.001, hypot(dx, dy))
        let ux = dx / len
        let uy = dy / len
        let nx = -uy
        let ny = ux

        let R = width * 0.5
        func radius(_ t: CGFloat) -> CGFloat { R * (0.97 - 0.09 * pow(t, 1.4)) }
        let hipR = radius(0)
        let shoulderR = radius(1)

        let start = CGPoint(x: hip.x - ux * hipDrop * len, y: hip.y - uy * hipDrop * len)
        let total = len + hipDrop * len

        var front: [CGPoint] = []
        var back: [CGPoint] = []
        let steps = 18
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let r = radius(t)
            front.append(CGPoint(x: start.x + ux * total * t + nx * r,
                                 y: start.y + uy * total * t + ny * r))
            back.append(CGPoint(x: start.x + ux * total * t - nx * r,
                                y: start.y + uy * total * t - ny * r))
        }

        var outline = front
        for i in 1..<8 {
            let phi = CGFloat.pi * CGFloat(i) / 8
            outline.append(CGPoint(x: shoulder.x + (nx * cos(phi) + ux * sin(phi)) * shoulderR,
                                   y: shoulder.y + (ny * cos(phi) + uy * sin(phi)) * shoulderR))
        }
        outline.append(contentsOf: back.reversed())
        for i in 1..<8 {
            let phi = CGFloat.pi + CGFloat.pi * CGFloat(i) / 8
            outline.append(CGPoint(x: start.x + (nx * cos(phi) + ux * sin(phi)) * hipR,
                                   y: start.y + (ny * cos(phi) + uy * sin(phi)) * hipR))
        }

        let path = CGMutablePath()
        path.move(to: outline[0])
        let n = outline.count
        for i in 0..<n {
            let p0 = outline[(i - 1 + n) % n]
            let p1 = outline[i]
            let p2 = outline[(i + 1) % n]
            let p3 = outline[(i + 2) % n]
            path.addCurve(to: p2,
                          control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                                            y: p1.y + (p2.y - p0.y) / 6),
                          control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                                            y: p2.y - (p3.y - p1.y) / 6))
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color)
        ctx.fillPath()
    }

    private static func stroke(_ ctx: CGContext, _ points: [CGPoint],
                               width: CGFloat, color: CGColor)
    {
        guard points.count > 1 else { return }
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: points[0])
        for p in points.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    private static func drawShadow(_ ctx: CGContext, hipX: CGFloat, groundY: CGFloat,
                                   H: CGFloat, air: CGFloat, palette: RunnerPalette)
    {
        let shrink = 1 - 0.26 * air
        let width = 0.560 * H * shrink
        let height = 0.046 * H
        let alpha = 0.095 - 0.035 * air
        ctx.setFillColor(palette.shadow.withAlphaComponent(alpha).cgColor)
        ctx.fillEllipse(in: CGRect(x: hipX + 0.020 * H - width / 2,
                                   y: groundY - height * 0.30,
                                   width: width, height: height))
    }

    private static func drawSpeedLines(_ ctx: CGContext, hipX: CGFloat,
                                       groundY: CGFloat, H: CGFloat, phase: Double)
    {
        for i in 0..<3 {
            let t = (phase * 2 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
            let k = CGFloat(t)
            let fade = CGFloat(sin(Double.pi * t))
            let y = groundY - (0.34 + 0.150 * CGFloat(i)) * H
            let length = (0.085 + 0.035 * CGFloat(i)) * H * (0.55 + 0.45 * fade)
            let x = hipX - 0.245 * H - k * 0.34 * H
            ctx.setStrokeColor(RunnerPalette.paper.speed.withAlphaComponent(0.10 * fade).cgColor)
            ctx.setLineWidth(max(1, 0.017 * H))
            ctx.setLineCap(.round)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x, y: y))
            ctx.addLine(to: CGPoint(x: x - length, y: y))
            ctx.strokePath()
        }
    }
}

/// 承载小人的视图：按相位逐帧重绘；优先用 CADisplayLink，拿不到窗口时退回 60Hz Timer。
@MainActor
final class RunnerAnimationView: NSView {
    private var link: CADisplayLink?
    private var fallback: Timer?
    private var startTime: CFTimeInterval = 0
    private var wantsAnimation = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        let time = wantsAnimation ? CACurrentMediaTime() - startTime : 0.85
        RunnerFigure.draw(in: ctx, rect: bounds,
                          phase: RunnerFigure.phase(at: time), palette: .paper)
    }

    func startAnimation() {
        guard !wantsAnimation else { return }
        wantsAnimation = true
        startTime = CACurrentMediaTime()
        needsDisplay = true
        startTicking()
    }

    func stopAnimation() {
        wantsAnimation = false
        stopTicking()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopTicking()
        } else if wantsAnimation {
            startTicking()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { stopTicking() }
    }

    private func startTicking() {
        guard wantsAnimation, link == nil, fallback == nil else { return }
        if window != nil {
            let l = displayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1.0 / 60.0, target: self,
                          selector: #selector(stepTimer), userInfo: nil, repeats: true)
            t.tolerance = 0
            RunLoop.main.add(t, forMode: .common)
            fallback = t
        }
    }

    private func stopTicking() {
        link?.invalidate()
        link = nil
        fallback?.invalidate()
        fallback = nil
    }

    @objc private func step(_ displayLink: CADisplayLink) {
        needsDisplay = true
    }

    @objc private func stepTimer() {
        needsDisplay = true
    }
}
