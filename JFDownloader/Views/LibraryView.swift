import SwiftUI

/// Titles on the leading side, the chosen title on the trailing side. Closed, the split view
/// collapses into one navigation stack; open, it shows both columns.
struct LibraryView: View {
    let client: JellyfinClient
    let account: AccountStore.Account

    @Environment(AccountStore.self) private var accounts
    @Environment(DownloadManager.self) private var downloads

    @State private var libraries: [JellyfinItem]?
    @State private var libraryId: String?
    @State private var searchText = ""
    @State private var items: [JellyfinItem] = []
    @State private var totalCount = 0
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var selectedId: String?
    @State private var selectedItem: JellyfinItem?
    @State private var confirmingSignOut = false

    private static let pageSize = 60

    private struct Query: Equatable {
        let libraryId: String?
        let search: String
        let librariesLoaded: Bool
    }

    var body: some View {
        NavigationSplitView {
            itemList
                .navigationTitle(title)
                .searchable(text: $searchText, prompt: "Movies and shows")
                .toolbar { toolbar }
        } detail: {
            NavigationStack {
                if let selectedItem {
                    ItemDetailView(item: selectedItem, client: client, account: account)
                } else {
                    ContentUnavailableView(
                        "Pick a Title",
                        systemImage: "film.stack",
                        description: Text("Choose a movie or show to download.")
                    )
                }
            }
            .id(selectedItem?.id)
        }
        .task { await loadLibraries() }
        .task(id: Query(libraryId: libraryId, search: searchText, librariesLoaded: libraries != nil)) {
            await reload()
        }
        .onChange(of: selectedId) { _, id in
            if let id, let item = items.first(where: { $0.id == id }) { selectedItem = item }
        }
        .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign Out and Cancel Downloads", role: .destructive) {
                downloads.removeUnfinished()
                Task { await accounts.signOut() }
            }
        } message: {
            Text("Unfinished downloads will be cancelled. Finished files stay in Files.")
        }
    }

    private var title: String {
        libraries?.first { $0.id == libraryId }?.name ?? "All Libraries"
    }

    @ViewBuilder private var itemList: some View {
        List(selection: $selectedId) {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Try Again", systemImage: "arrow.clockwise") { Task { await reload() } }
                }
            }
            ForEach(items) { item in
                NavigationLink(value: item.id) {
                    ItemRow(item: item, client: client)
                }
                .onAppear {
                    if item.id == items.last?.id { Task { await loadMore() } }
                }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .overlay {
            if !isLoading, loadError == nil, items.isEmpty, libraries != nil {
                if searchText.isEmpty {
                    ContentUnavailableView("Nothing Here", systemImage: "film", description: Text("This library has no movies or shows."))
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            }
        }
        .refreshable { await reload() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Menu {
                Section("\(account.userName) on \(account.serverName ?? account.serverURL.host() ?? "Jellyfin")") {
                    Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        if downloads.jobs.contains(where: { $0.status != .completed }) {
                            confirmingSignOut = true
                        } else {
                            Task { await accounts.signOut() }
                        }
                    }
                }
            } label: {
                Label("Account", systemImage: "person.crop.circle")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Library", selection: $libraryId) {
                    Label("All Libraries", systemImage: "square.stack").tag(String?.none)
                    ForEach(libraries ?? []) { library in
                        Label(library.name, systemImage: library.collectionType == "tvshows" ? "tv" : "film")
                            .tag(Optional(library.id))
                    }
                }
            } label: {
                Label("Library", systemImage: "books.vertical")
            }
            .accessibilityIdentifier("library.picker")
        }
    }

    // MARK: Loading

    private func loadLibraries() async {
        guard libraries == nil else { return }
        do {
            let found = try await client.libraries(userId: account.userId)
            libraryId = found.first?.id
            libraries = found
        } catch {
            loadError = error.localizedDescription
            libraries = []
        }
    }

    private func reload() async {
        guard libraries != nil else { return }
        if !searchText.isEmpty {
            // Debounce typing; a newer query cancels this task.
            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.items(
                userId: account.userId,
                parentId: searchText.isEmpty ? libraryId : nil,
                searchTerm: searchText,
                startIndex: 0,
                limit: Self.pageSize
            )
            items = page.items
            totalCount = page.totalRecordCount
            loadError = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !isLoading, items.count < totalCount else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.items(
                userId: account.userId,
                parentId: searchText.isEmpty ? libraryId : nil,
                searchTerm: searchText,
                startIndex: items.count,
                limit: Self.pageSize
            )
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            totalCount = page.totalRecordCount
        } catch {
            loadError = error.localizedDescription
        }
    }
}

private struct ItemRow: View {
    let item: JellyfinItem
    let client: JellyfinClient
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        HStack(spacing: 12) {
            Artwork(url: client.imageURL(itemId: item.id, tag: item.primaryImageTag, maxWidth: 120))
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.body).lineLimit(2)
                Text(item.metadataLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if downloads.jobs.contains(where: { $0.itemId == item.id && $0.status == .completed }) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Downloaded")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("item.\(item.name)")
    }
}
