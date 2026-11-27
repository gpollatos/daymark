import SwiftUI
import UniformTypeIdentifiers

/// One-time setup: Google requires every app to have its own OAuth client ID.
struct SetupView: View {
    @Environment(CalendarStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let inSettings: Bool

    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect Daymark to Google")
                    .font(.title2.weight(.semibold))
                Text("Google only lets an app sign in with its own OAuth client. You set this up once (about 5 minutes); after that you add accounts with a normal Google sign-in, as on your iPhone.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    step(1, "Create a project in Google Cloud Console.",
                         link: ("Create project", "https://console.cloud.google.com/projectcreate"))
                    step(2, "Enable the Google Calendar API for that project.",
                         link: ("Enable Calendar API", "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com"))
                    step(3, "Open Google Auth Platform and click Get started. App name: Daymark; audience: External; use your email for the contact fields.",
                         link: ("Google Auth Platform", "https://console.cloud.google.com/auth/overview"))
                    step(4, "Under Audience → Test users, add every Google account you'll connect. (In Testing mode Google signs you out every 7 days; see the README to publish instead.)",
                         link: ("Audience", "https://console.cloud.google.com/auth/audience"))
                    step(5, "Under Clients, click Create client and choose Desktop app. Paste the Client ID and secret below, or download the JSON file and import it.",
                         link: ("Clients", "https://console.cloud.google.com/auth/clients"))
                }

                Form {
                    TextField("Client ID", text: $clientId, prompt: Text("1234…apps.googleusercontent.com"))
                    SecureField("Client secret", text: $clientSecret, prompt: Text("GOCSPX-…"))
                }
                .formStyle(.grouped)

                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }

                HStack {
                    Button("Import JSON…") { importing = true }
                    Spacer()
                    if store.client != nil && !inSettings {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    Button(inSettings ? "Save" : "Continue") { save() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(clientId.trimmed.isEmpty || clientSecret.trimmed.isEmpty)
                }

                if inSettings && store.client != nil {
                    Text("Changing the client signs out every account; you'll need to reconnect each one.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(width: 600, height: 640)
        .onAppear {
            clientId = store.client?.clientId ?? ""
            clientSecret = store.client?.clientSecret ?? ""
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            importJSON(result)
        }
    }

    private func step(_ n: Int, _ text: String, link: (String, String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Palette.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                Link("\(link.0) ↗", destination: URL(string: link.1)!).font(.callout)
            }
        }
    }

    private func save() {
        let c = OAuthClient(clientId: clientId.trimmed, clientSecret: clientSecret.trimmed)
        guard OAuthClient.isPlausibleId(c.clientId) else {
            error = "That doesn't look like a Google OAuth client ID."
            return
        }
        store.saveClient(c)
        if !inSettings { dismiss() }
        if store.accounts.isEmpty { store.addAccount() }
    }

    private func importJSON(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let c = OAuthClient.fromGoogleJSON(try Data(contentsOf: url)) else {
                error = "That file isn't a Google OAuth client JSON."
                return
            }
            let id = c.clientId, secret = c.clientSecret
            clientId = id
            clientSecret = secret
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
