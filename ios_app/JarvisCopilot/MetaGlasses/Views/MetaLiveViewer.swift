import AVFoundation
import SwiftUI

/// What the glasses stream to the phone, full screen: the iPhone camera standing in for the
/// glasses camera, held to the glasses' 720×1280 live format, with the stream's state over it.
/// The glasses' limits still apply: cover the LED, overheat or run the battery down and the stream
/// ends here the way it would on the real glasses.
struct MetaLiveViewer: View {
    @ObservedObject var sim: SimulatedGlassesTransport
    let stop: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// Just the glasses' video, full screen — for FaceTime's Share My Screen. Tap to bring the controls back.
    @State private var callView = false
    @State private var showingFaceTimeHelp = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                let width = min(geo.size.width, geo.size.height * 9 / 16)
                video
                    .frame(width: width, height: width * 16 / 9)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .padding(.vertical, callView ? 0 : 60)
            if callView {
                // A small LIVE dot is the only chrome, so the person on the call sees the glasses' view.
                VStack {
                    HStack {
                        Circle().fill(Color.red).frame(width: 8, height: 8).padding(10)
                        Spacer()
                    }
                    Spacer()
                }
            } else {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .padding(16)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if callView { withAnimation(.easeInOut(duration: 0.2)) { callView = false } } }
        .statusBarHidden()
        .persistentSystemOverlays(callView ? .hidden : .automatic)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $showingFaceTimeHelp) { MetaFaceTimeHelp() }
    }

    @ViewBuilder private var video: some View {
        if sim.hw.streaming, let session = sim.livePreviewSession {
            MetaCameraPreview(session: session)
        } else if sim.hw.streaming, let data = sim.latestLiveFrame, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color(white: 0.08)
                VStack(spacing: 8) {
                    Image(systemName: sim.hw.streaming ? "hourglass" : "video.slash").font(.system(size: 28))
                    Text(sim.hw.streaming ? "Waiting for the glasses…" : "Stream ended")
                        .font(.system(size: 16, weight: .semibold))
                    if !sim.hw.streaming, let why = sim.liveEndReason {
                        Text(why).font(.system(size: 13)).foregroundStyle(JcTheme.muted).multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(JcTheme.text)
                .padding()
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            if sim.hw.streaming {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("LIVE").font(.system(size: 13, weight: .bold))
                    if let started = sim.liveStartedAt {
                        TimelineView(.periodic(from: started, by: 1)) { context in
                            Text(Self.clock(context.date.timeIntervalSince(started)))
                                .font(.system(size: 13, weight: .medium).monospacedDigit())
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.55)))
            }
            Spacer()
            Text("\(MetaGen2Profile.liveWidth)×\(MetaGen2Profile.liveHeight) · \(MetaGen2Profile.liveFPS) fps · \(sim.cameraName)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.55)))
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                chip(sim.hw.charging ? "battery.100.bolt" : "battery.75", "\(Int(sim.hw.battery.rounded()))%")
                chip("thermometer.medium", sim.hw.heatLabel)
                if sim.phoneOnGlassesWiFi { chip("wifi", "Phone on the glasses' Wi-Fi") }
            }
            HStack(spacing: 10) {
                Button { showingFaceTimeHelp = true } label: {
                    Label("FaceTime", systemImage: "video.badge.waveform").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.jcGlass)
                if sim.hw.streaming {
                    Button { withAnimation(.easeInOut(duration: 0.2)) { callView = true } } label: {
                        Label("Call view", systemImage: "rectangle.inset.filled").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.jcGlass)
                }
            }
            HStack(spacing: 10) {
                if sim.hw.streaming {
                    Button(action: stop) {
                        Label("Stop stream", systemImage: "stop.fill").frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.jcGlass)
                }
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.jcGlass)
            }
        }
    }

    private func chip(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.55)))
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// How to put the glasses' view into a FaceTime call. iOS gives no app a way to be FaceTime's
/// camera (no external or virtual cameras on iPhone), so the route is FaceTime's own screen sharing.
private struct MetaFaceTimeHelp: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Show your glasses' view in a FaceTime call")
                        .font(.system(size: 20, weight: .semibold))
                    step(1, "Start the FaceTime call as usual.")
                    step(2, "Tap the Share button in the call controls (the rectangle with a person), then Share My Screen.")
                    step(3, "Come back to Jarvis: Meta glasses → Watch live → Call view.")
                    step(4, "The other person now sees exactly what your glasses see. Tap the video to get the controls back; stop sharing from FaceTime's controls.")
                    Text("Good to know")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.top, 6)
                    note("Keep Jarvis open while sharing. FaceTime stays in picture-in-picture.")
                    note("With the real glasses, their live video moves your phone onto the glasses' Wi-Fi, so FaceTime runs over cellular.")
                    note("In the simulator the iPhone camera is the glasses camera, and FaceTime takes it during a call, so the sim's view may pause. The real glasses send their own video.")
                    note("Want a true camera called “Jarvis Glasses”? That's coming on the Mac, where FaceTime, Zoom and Meet can pick it.")
                }
                .padding(20)
            }
            .background(JcTheme.bg.ignoresSafeArea())
            .navigationTitle("FaceTime")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.system(size: 13, weight: .bold)).foregroundStyle(JcAccent.onFill)
                .frame(width: 22, height: 22).background(Circle().fill(JcAccent.fill))
            Text(text).font(.system(size: 15)).foregroundStyle(JcTheme.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.system(size: 13)).foregroundStyle(JcTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The camera's live picture, portrait, filling its frame.
struct MetaCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
