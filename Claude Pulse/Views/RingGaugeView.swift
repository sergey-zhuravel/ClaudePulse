//
//  RingGaugeView.swift
//  Claude Pulse
//
//  Created by Sergey Zhuravel on 4/9/26.
//

import SwiftUI

struct RingGaugeView: View {
    let fraction: Double       // 0.0 – 1.0
    let consumedCount: Int
    let totalCapacity: Int
    var strokeWidth: CGFloat = 14
    
    private var percentValue: Int { Int(fraction * 100) }
    
    // Gradient starts at -90° (top/12 o'clock) — matches ArcSegment start angle exactly.
    // No rotationEffect needed, so there is no double-rotation offset.
    private let arcGradient = AngularGradient(
        stops: [
            .init(color: .green,  location: 0.00),
            .init(color: .yellow, location: 0.50),
            .init(color: .orange, location: 0.70),
            .init(color: .red,    location: 0.85),
            .init(color: .red,    location: 1.00),
        ],
        center: .center,
        startAngle: .degrees(-90),
        endAngle:   .degrees(270)
    )
    
    var body: some View {
        ZStack {
            // Background track
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: strokeWidth)
            
            // Coloured progress arc — custom Shape so startAngle is -90° by
            // construction; no rotationEffect means the gradient angles align.
            ArcSegment(fraction: fraction)
                .stroke(
                    arcGradient,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .animation(.spring(response: 0.7, dampingFraction: 0.8), value: fraction)
            
            // Green dot at arc origin (12 o'clock).
            // The AngularGradient wraps at -90°/270° so the round start cap
            // would show half-green / half-red. This dot covers that artefact.
            GeometryReader { geo in
                let side = min(geo.size.width, geo.size.height)
                Circle()
                    .fill(Color.green)
                    .frame(width: strokeWidth, height: strokeWidth)
                    .position(x: geo.size.width / 2,
                              y: (geo.size.height - side) / 2)
            }
            .opacity(fraction > 0.01 ? 1 : 0)
            
            // Central labels
            VStack(spacing: 4) {
                Text("\(percentValue)%")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(statusTint)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.4), value: percentValue)
                
                if totalCapacity > 0 {
                    Text("\(consumedCount) of \(totalCapacity)")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No data")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
    
    private var statusTint: Color {
        switch fraction {
        case 0.8...: return .red
        case 0.5...: return .orange
        default:     return .green
        }
    }
}

// MARK: - Arc Shape

/// Draws a clockwise arc from -90° (12 o'clock) to the given fraction.
/// Using a custom Shape avoids the need for `.rotationEffect` which would also
/// rotate the AngularGradient and misalign its colours.
private struct ArcSegment: Shape {
    var fraction: Double
    
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }
    
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        return Path { p in
            p.addArc(
                center:     center,
                radius:     radius,
                startAngle: .degrees(-90),
                endAngle:   .degrees(-90 + 360 * max(0.005, fraction)),
                clockwise:  false
            )
        }
    }
}
