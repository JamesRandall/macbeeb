import AppKit
import BeebNetwork
import SwiftUI

/// Network ▸ Share Over Internet: put this network's machines in a private
/// room others join with a link or a code; then the room's invitation,
/// who's in it, and the host's controls. For a network that joined someone
/// else's room, the room and leaving it.
struct InternetShareView: View {
    let session: NetworkSession
    @Environment(\.dismiss) private var dismiss
    @State private var roomName = ""
    @State private var displayName = NetworkSession.roomDisplayName
    @State private var shared: Set<UUID> = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingStop = false
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.isInRoom {
                inRoom
            } else {
                setUp
            }
        }
        .frame(width: 520)
        .onAppear {
            roomName = session.project.name
            shared = Set(session.project.internetRoom?.shared ?? defaultShared)
        }
        .alert("Internet Econet", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Machines shared by default: stations, not servers (sharing a server
    /// is a decision).
    private var defaultShared: [UUID] {
        session.project.stations.filter { $0.kind == .station }.map(\.id)
    }

    private var service: URL { InternetEconetService.current }

    // MARK: Before sharing

    private var setUp: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 30))
                    .foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Over the Internet")
                        .font(.title2.weight(.semibold))
                    Text("A private Econet network others join with a link or a code. Their BBC Micros appear on your network, and yours on theirs.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Form {
                TextField("Network name", text: $roomName)
                TextField("Your name", text: $displayName, prompt: Text("Shown to people who join"))
                LabeledContent("Service") {
                    Text(service.host ?? service.absoluteString)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            machineList
            Text("Only Econet is shared: people who join can't see your screens, type into your machines or reach anything else on your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    if busy { ProgressView().controlSize(.small) } else { Text("Create Private Network") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(busy || roomName.trimmingCharacters(in: .whitespaces).isEmpty || shared.isEmpty)
            }
        }
        .padding(20)
    }

    private var machineList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Machines to share")
                .font(.headline)
            ForEach(session.project.stations) { node in
                HStack {
                    Toggle(isOn: Binding(get: { shared.contains(node.id) }, set: { on in
                        if on { shared.insert(node.id) } else { shared.remove(node.id) }
                        if session.isInRoom { session.setShared(shared) }
                    })) {
                        HStack(spacing: 6) {
                            StationBadge(number: node.stationNumber)
                            Text(node.name)
                            Text(node.setup?.model.displayName ?? "")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                if node.kind != .station && shared.contains(node.id) {
                    Label(node.kind == .fileServer
                          ? "People who join can log on to this file server and read and write whatever its accounts allow."
                          : "People who join can print on this printer server: their jobs appear in your Print Centre.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.leading, 24)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func create() {
        busy = true
        NetworkSession.roomDisplayName = displayName.trimmingCharacters(in: .whitespaces)
        Task {
            defer { busy = false }
            do {
                try await session.share(on: service, name: roomName.trimmingCharacters(in: .whitespaces), shared: shared)
            } catch {
                self.error = "Couldn't create the network: \(error)"
            }
        }
    }

    // MARK: Shared

    private var inRoom: some View {
        let link = session.project.internetRoom
        let room = session.room
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room?.room?.name ?? link?.roomName ?? "")
                        .font(.title2.weight(.semibold))
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ConnectionBadge(state: room?.state)
            }
            if let problem = room?.problem, room?.state != .connected {
                Label(problem, systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
            }
            if case .ended(let reason) = room?.state {
                Label(reason, systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
            if link?.hosting == true {
                invitation
            }
            participants
            if let refused = room?.refused, !refused.isEmpty {
                ForEach(refused.keys.sorted(), id: \.self) { station in
                    Label("Station \(station) is already in the room: change this network's station \(station) to share it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            DisclosureGroup("Machines shared") {
                machineList
                    .padding(.top, 6)
            }
            HStack {
                if link?.hosting == true {
                    Toggle("Let new people join", isOn: Binding(get: { room?.room?.locked != true }, set: { open in
                        Task { try? await session.setRoomLocked(!open) }
                    }))
                    .toggleStyle(.checkbox)
                }
                Spacer()
                Button(link?.hosting == true ? "Stop Sharing…" : "Leave Network…", role: .destructive) { confirmingStop = true }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .confirmationDialog(link?.hosting == true ? "Stop sharing this network?" : "Leave this network?", isPresented: $confirmingStop) {
            Button(link?.hosting == true ? "Stop Sharing" : "Leave", role: .destructive) {
                Task { await session.leaveRoom() }
            }
        } message: {
            Text(link?.hosting == true
                 ? "The network closes for everyone in it: their machines disappear from yours, and yours from theirs. Its link and code stop working."
                 : "Your machines leave the network, and its machines disappear from yours.")
        }
    }

    private var summary: String {
        let people = session.room?.participants.count ?? 0
        let host = session.project.internetRoom?.service.host ?? ""
        return "Private · \(people) \(people == 1 ? "person" : "people") · \(host)"
    }

    @ViewBuilder
    private var invitation: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let invite = session.currentInvite {
                HStack {
                    Text("Join code")
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(invite.code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                    Spacer()
                    copyButton(invite.code, label: "Copy Code")
                }
                HStack {
                    Text("Invite link")
                        .foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(invite.url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    copyButton(invite.url, label: "Copy Link")
                }
                HStack {
                    Text("Works for 24 hours, for up to \(invite.maxUses) people.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Withdraw") { Task { try? await session.withdrawInvitation() } }
                        .help("The link and code stop working; anyone already in stays")
                    Button("New Invitation") { Task { try? await session.newInvitation() } }
                }
            } else {
                HStack {
                    Text("Make an invitation to let someone join: a link to send, or a code to read out.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("New Invitation") {
                        Task {
                            do { try await session.newInvitation() } catch { self.error = "\(error)" }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func copyButton(_ text: String, label: String) -> some View {
        Button(copied == text ? "Copied" : label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = text
        }
    }

    @ViewBuilder
    private var participants: some View {
        let room = session.room
        VStack(alignment: .leading, spacing: 6) {
            Text("In the network")
                .font(.headline)
            ForEach(room?.participants ?? []) { person in
                let isMe = person.id == room?.participantId
                let stations = (room?.stations ?? []).filter { $0.participantId == person.id }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(person.online ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name + (isMe ? " (you)" : "") + (person.owner ? " · host" : ""))
                        Text(stations.isEmpty ? "No machines" : stations.map { "\($0.station) \($0.label)" }.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let rtt = person.rttMs, person.online {
                        Text("\(rtt) ms")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if session.project.internetRoom?.hosting == true && !isMe {
                        Button("Remove") { Task { try? await session.removeFromRoom(person.id) } }
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Connected, reconnecting, or not.
struct ConnectionBadge: View {
    let state: RoomConnection.State?

    var body: some View {
        let (text, colour): (String, Color) = switch state {
        case .connected: ("Connected", .green)
        case .connecting, nil: ("Connecting…", .orange)
        case .reconnecting: ("Reconnecting…", .orange)
        case .ended: ("Disconnected", .red)
        case .stopped: ("Not connected", .secondary)
        }
        Label {
            Text(text)
        } icon: {
            Circle().fill(colour).frame(width: 8, height: 8)
        }
        .font(.callout)
    }
}
