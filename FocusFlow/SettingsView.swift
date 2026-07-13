import SwiftUI
import UIKit
import MessageUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("silenceTimeout") private var silenceTimeout: String = "default"
    @State private var showMail = false
    @State private var showMailUnavailable = false

    static let feedbackEmail = "triology602@gmail.com"

    var body: some View {
        ZStack {
            Color.bdBg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Back").font(.bdCaption())
                        }
                        .foregroundStyle(Color.bdMuted)
                    }
                    Spacer()
                    Text("Settings").font(.bdBody()).foregroundStyle(.white)
                    Spacer()
                    // balance
                    Text("Back").font(.bdCaption()).opacity(0)
                }
                .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 24)

                ScrollView {
                    VStack(spacing: 20) {
                        settingCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("AUTO-STOP SENSITIVITY")
                                    .font(.bdMicro()).foregroundStyle(Color.bdMuted)

                                Text("How long after you stop speaking before recording auto-stops.")
                                    .font(.system(size: 13)).foregroundStyle(Color.bdMuted)
                                    .fixedSize(horizontal: false, vertical: true)

                                Picker("", selection: $silenceTimeout) {
                                    Text("Fast  1.5s").tag("fast")
                                    Text("Default  2.5s").tag("default")
                                    Text("Relaxed  4s").tag("relaxed")
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(18)
                        }

                        settingCard {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("VOICE LANGUAGE")
                                        .font(.bdMicro()).foregroundStyle(Color.bdMuted)
                                    Text("English (US)")
                                        .font(.bdBody()).foregroundStyle(.white)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(Color.bdMuted2)
                            }
                            .padding(18)
                        }

                        settingCard {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("AI PROCESSING")
                                        .font(.bdMicro()).foregroundStyle(Color.bdMuted)
                                    Text("On-device only")
                                        .font(.bdBody()).foregroundStyle(.white)
                                    Text("No data ever leaves your device.")
                                        .font(.system(size: 12)).foregroundStyle(Color.bdMuted)
                                }
                                Spacer()
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 20)).foregroundStyle(Color.bdGreen)
                            }
                            .padding(18)
                        }

                        Button {
                            if MFMailComposeViewController.canSendMail() { showMail = true }
                            else { showMailUnavailable = true }
                        } label: {
                            settingCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("FEEDBACK")
                                            .font(.bdMicro()).foregroundStyle(Color.bdMuted)
                                        Text("Send feedback")
                                            .font(.bdBody()).foregroundStyle(.white)
                                        Text("Ideas, bugs, or anything else. Goes straight to the developer.")
                                            .font(.system(size: 12)).foregroundStyle(Color.bdMuted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Image(systemName: "envelope.fill")
                                        .font(.system(size: 18)).foregroundStyle(Color.bdMuted2)
                                }
                                .padding(18)
                            }
                        }
                        .buttonStyle(.plain)

                        #if DEBUG
                        NavigationLink {
                            EvalRunnerView()
                        } label: {
                            settingCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("DEVELOPER")
                                            .font(.bdMicro()).foregroundStyle(Color.bdMuted)
                                        Text("Run QA Eval Suite")
                                            .font(.bdBody()).foregroundStyle(.white)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(Color.bdMuted2)
                                }
                                .padding(18)
                            }
                        }
                        .buttonStyle(.plain)
                        #endif
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showMail) {
            MailView(recipient: Self.feedbackEmail,
                     subject: "Voxdump Feedback",
                     body: SettingsView.feedbackBody())
                .ignoresSafeArea()
        }
        .alert("Mail isn't set up", isPresented: $showMailUnavailable) {
            Button("Copy address") { UIPasteboard.general.string = Self.feedbackEmail }
            Button("OK", role: .cancel) { }
        } message: {
            Text("Add a Mail account in Settings, or email \(Self.feedbackEmail) directly.")
        }
    }

    static func feedbackBody() -> String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let d = UIDevice.current
        return """


        --- diagnostics (please keep) ---
        Voxdump \(v) (\(b))
        \(d.systemName) \(d.systemVersion)
        """
    }

    private func settingCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.bdCard))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.bdBorder, lineWidth: 1))
    }
}

/// SwiftUI wrapper around MFMailComposeViewController for in-app feedback.
/// No backend: opens the user's Mail app pre-addressed to the developer, keeping
/// the app's "nothing leaves your device without you sending it" promise intact.
struct MailView: UIViewControllerRepresentable {
    let recipient: String
    let subject: String
    let body: String
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients([recipient])
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        return vc
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        private let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            dismiss()
        }
    }
}
