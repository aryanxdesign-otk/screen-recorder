import SwiftUI

struct CropSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var image: CGImage?
    @State private var moveOrigin: CGRect?

    private let minimumSize = 0.08

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Crop")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Text("\(Int(crop.width * model.sourceSize.width)) × \(Int(crop.height * model.sourceSize.height))")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }

            GeometryReader { geo in
                let aspect = model.sourceSize.width / max(model.sourceSize.height, 1)
                let fitted = fit(aspect: aspect, in: geo.size)
                let rect = CGRect(
                    x: crop.minX * fitted.width,
                    y: crop.minY * fitted.height,
                    width: crop.width * fitted.width,
                    height: crop.height * fitted.height
                )

                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                    } else {
                        Color.white.opacity(0.06)
                            .overlay(ProgressView().controlSize(.small))
                    }
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: fitted))
                        path.addRect(rect)
                    }
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 2)
                        .frame(width: rect.width, height: rect.height)
                        .contentShape(Rectangle())
                        .offset(x: rect.minX, y: rect.minY)
                        .gesture(moveGesture(fitted: fitted))

                    ForEach(Corner.allCases, id: \.self) { corner in
                        let point = position(of: corner, in: rect)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.4), radius: 2)
                            .offset(x: point.x - 7, y: point.y - 7)
                            .gesture(
                                DragGesture(minimumDistance: 0, coordinateSpace: .named("crop"))
                                    .onChanged { value in resize(corner, to: value.location, fitted: fitted) }
                            )
                    }
                }
                .frame(width: fitted.width, height: fitted.height, alignment: .topLeading)
                .coordinateSpace(name: "crop")
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .frame(height: 440)

            HStack {
                Button("Reset") { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    model.state.crop = crop
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 780)
        .preferredColorScheme(.dark)
        .onAppear { crop = model.state.crop }
        .task {
            let time = model.timeMap.sourceTime(atOutput: model.currentTime)
            image = await model.sourceFrame(atSource: time, maxSize: CGSize(width: 1600, height: 1600))
        }
    }

    private func fit(aspect: Double, in size: CGSize) -> CGSize {
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGSize(width: width, height: height)
    }

    private func position(of corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private func resize(_ corner: Corner, to location: CGPoint, fitted: CGSize) {
        let x = (location.x / fitted.width).clamped(to: 0...1)
        let y = (location.y / fitted.height).clamped(to: 0...1)
        var minX = crop.minX, maxX = crop.maxX, minY = crop.minY, maxY = crop.maxY
        switch corner {
        case .topLeft:
            minX = min(x, maxX - minimumSize)
            minY = min(y, maxY - minimumSize)
        case .topRight:
            maxX = max(x, minX + minimumSize)
            minY = min(y, maxY - minimumSize)
        case .bottomLeft:
            minX = min(x, maxX - minimumSize)
            maxY = max(y, minY + minimumSize)
        case .bottomRight:
            maxX = max(x, minX + minimumSize)
            maxY = max(y, minY + minimumSize)
        }
        crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func moveGesture(fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("crop"))
            .onChanged { value in
                let origin = moveOrigin ?? crop
                if moveOrigin == nil { moveOrigin = crop }
                let dx = value.translation.width / fitted.width
                let dy = value.translation.height / fitted.height
                let x = (origin.minX + dx).clamped(to: 0...(1 - origin.width))
                let y = (origin.minY + dy).clamped(to: 0...(1 - origin.height))
                crop = CGRect(x: x, y: y, width: origin.width, height: origin.height)
            }
            .onEnded { _ in moveOrigin = nil }
    }
}
