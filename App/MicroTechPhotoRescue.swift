// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum CardKind: String, CaseIterable, Identifiable {
    case smartMedia = "SmartMedia", compactFlash = "CompactFlash"
    var id: String { rawValue }
    var helper: String { self == .smartMedia ? "microtech_smartmedia" : "microtech_probe" }
}
struct Photo: Identifiable {
    let url: URL
    let thumbnail: NSImage?
    var id: String { url.path }
    init(_ url: URL) {
        self.url = url
        if let source = CGImageSourceCreateWithURL(url as CFURL,nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,
             kCGImageSourceThumbnailMaxPixelSize:300,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) {
            thumbnail = NSImage(cgImage:image,size:.zero)
        } else { thumbnail = nil }
    }
}
struct CardCheckResult {
    let succeeded: Bool
    let kind: CardKind
    var title: String { succeeded ? "\(kind.rawValue) card read successfully" : "\(kind.rawValue) card could not be read" }
    var guidance: String {
        if succeeded { return "Your card is ready. Choose Import Photos to copy your pictures." }
        if kind == .smartMedia { return "Insert a SmartMedia card into the lower slot. If it is already inserted, remove it, flip it over so the gold contacts face up, and try Check Card again." }
        return "Insert a CompactFlash card fully into the upper slot, then try Check Card again. CompactFlash fits in only one direction; do not force it."
    }
}

struct CardCheckResultView: View {
    let result: CardCheckResult
    var body: some View {
        VStack(spacing:18) {
            Image(systemName:result.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size:64)).foregroundStyle(result.succeeded ? Color.green : Color.red)
            Text(result.title).font(.system(size:20,weight:.semibold)).multilineTextAlignment(.center)
            Text(result.guidance).font(.system(size:13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth:420)
            if !result.succeeded {
                Text("Make sure the USB reader is connected to your Mac.").font(.system(size:12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }.padding(28).frame(maxWidth:.infinity,maxHeight:.infinity)
            .background((result.succeeded ? Color.green : Color.red).opacity(0.045),in:RoundedRectangle(cornerRadius:16))
    }
}

struct NextStepButtonStyle: ButtonStyle {
    let highlighted: Bool
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size:13,weight:.medium))
            .padding(.horizontal,12).padding(.vertical,10)
            .frame(maxWidth:.infinity)
            .foregroundStyle(highlighted && isEnabled ? Color.white : Color.primary)
            .background(highlighted && isEnabled ? Color(red:0.12,green:0.62,blue:0.30) : Color(nsColor:.controlColor),in:RoundedRectangle(cornerRadius:8))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}

struct AppFailure: LocalizedError { let errorDescription: String? }

@MainActor final class ReaderModel: ObservableObject {
    @Published var kind: CardKind = .smartMedia
    @Published var status = "Ready to import photos"
    @Published var detail = "Connect your MicroTech DPCM-USB reader and insert a card."
    @Published var busy = false
    @Published var log = ""
    @Published var error: String?
    @Published var cardCheckResult: CardCheckResult?
    @Published var photos = [Photo]()
    @Published var session: URL?
    @Published var progress = 0.0
    @Published var hasProgress = false
    @Published var destination = FileManager.default.urls(for:.picturesDirectory,in:.userDomainMask).first!.appendingPathComponent("Microtech Imports")
    private var process: Process?
    private var cancelled = false
    var photosFolder: URL? { session?.appendingPathComponent("Photos") }
    func helper(_ name: String) throws -> URL {
        guard let url = Bundle.main.url(forResource:name,withExtension:nil,subdirectory:"Tools") else {
            throw AppFailure(errorDescription:"A bundled reader tool is missing. Rebuild or reinstall the app.")
        }
        return url
    }
    func append(_ text: String) {
        log += text
        if log.count > 80000 { log = String(log.suffix(80000)) }
        for line in text.split(separator:"\n") where line.hasPrefix("Read ") {
            let fields = line.split(separator:" ")
            if fields.count > 1 {
                let values = fields[1].split(separator:"/")
                if values.count == 2, let n = Double(values[0]), let d = Double(values[1]), d > 0 {
                    progress = min(1,n/d); hasProgress = true
                }
            }
        }
    }
    func run(_ executable: URL, _ args: [String]) async throws {
        if cancelled { throw CancellationError() }
        let job = Process(), pipe = Pipe()
        job.executableURL = executable; job.arguments = args
        job.standardOutput = pipe; job.standardError = pipe
        process = job
        try job.run()
        let code: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                while true {
                    let bytes = pipe.fileHandleForReading.availableData
                    if bytes.isEmpty { break }
                    let chunk = String(decoding:bytes,as:UTF8.self)
                    DispatchQueue.main.async { self.append(chunk) }
                }
                job.waitUntilExit()
                continuation.resume(returning:job.terminationStatus)
            }
        }
        process = nil
        if cancelled { throw CancellationError() }
        if code != 0 {
            throw AppFailure(errorDescription:"The import stopped. Files already copied are kept in the import folder. See Details for the reader’s response.")
        }
    }
    func start(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        cardCheckResult = nil
        busy = true; cancelled = false; error = nil; progress = 0; hasProgress = false; log = ""
        Task {
            defer { busy = false; process = nil; hasProgress = false }
            do { try await action() }
            catch is CancellationError { status = "Import stopped"; detail = "Files already copied are preserved in the import folder."; saveLog() }
            catch { self.error = error.localizedDescription; status = "Needs attention"; detail = "Check the card orientation and reader connection, then review Details."; saveLog() }
        }
    }
    func checkCard() {
        let selected = kind
        start {
            self.status = "Checking \(selected.rawValue)"; self.detail = "Identifying the card and testing communication…"
            do {
                try await self.run(self.helper(selected.helper),[])
                self.cardCheckResult = CardCheckResult(succeeded:true,kind:selected)
                self.status = "Ready to import photos"
                self.detail = "The card check completed successfully."
            } catch is CancellationError {
                self.status = "Card check stopped"; self.detail = "Choose Check Card to try again."
            } catch {
                self.cardCheckResult = CardCheckResult(succeeded:false,kind:selected)
                self.status = "Check your card"
                self.detail = "Adjust the card or reader connection, then check again."
            }
        }
    }
    func chooseDestination() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Save Photos Here"
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }
    func makeSession(_ name: String) throws -> URL {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let folder = destination.appendingPathComponent("\(name) \(formatter.string(from:Date())) \(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        session = folder; photos = []
        return folder
    }
    func saveLog() {
        guard let session = session else { return }
        try? log.write(to:session.appendingPathComponent("Import Log.txt"),atomically:true,encoding:.utf8)
    }
    func importPhotos() {
        let selected = kind
        start {
            let folder = try self.makeSession(selected.rawValue)
            let image = folder.appendingPathComponent("Card.img")
            let capture = selected == .smartMedia ? folder.appendingPathComponent("Card.raw") : image
            self.status = "Copying \(selected.rawValue)"; self.detail = "Reading your pictures from the card. Leave the reader connected."
            try await self.run(self.helper(selected.helper),[capture.path])
            self.saveLog(); self.progress = 0; self.status = "Checking the card copy"
            self.detail = "Reading the card again and comparing its data with the saved copy."
            try await self.run(self.helper(selected.helper),["--verify",capture.path])
            if selected == .smartMedia {
                self.status = "Preparing photos"; self.hasProgress = false
                self.detail = "Preparing the card contents for import."
                try await self.run(self.helper("recovery-engine"),["reconstruct",capture.path,image.path])
            }
            try await self.extract(image,folder:folder)
        }
    }
    func extract(_ image: URL, folder: URL) async throws {
        status = "Importing photos"; detail = "Copying photos and checking that images decode."; hasProgress = false
        let output = folder.appendingPathComponent("Photos")
        try await run(helper("recovery-engine"),["extract",image.path,output.path])
        let enumerator = FileManager.default.enumerator(at:output,includingPropertiesForKeys:nil)
        let urls = (enumerator?.allObjects as? [URL] ?? []).filter { ["jpg","jpeg","tif","tiff","png","gif","bmp","mov","avi","mp4","qt"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        photos = urls.map(Photo.init)
        let report = try Data(contentsOf:folder.appendingPathComponent("photos-report.json"))
        let results = try JSONSerialization.jsonObject(with:report) as? [String:Any]
        let failures = results?["decodeFailures"] as? Int ?? 0
        let dateWarnings = results?["datePreservationWarnings"] as? Int ?? 0
        status = photos.isEmpty ? "No photos found" : "\(photos.count) files imported"
        detail = photos.isEmpty ? "No photo or video files were found on this card." : failures == 0 ? "Your photos are copied to the Mac and ready to view. You can safely remove the card." : "Files are copied; \(failures) images could not be opened. See Details for more information."
        if dateWarnings > 0 { detail += " Original dates could not be set for \(dateWarnings) files; see photos-report.json in the import folder." }
        saveLog()
        if !photos.isEmpty { NSWorkspace.shared.open(output) }
    }
    func importImage() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["img","raw","bin"].compactMap { UTType(filenameExtension:$0) }; panel.prompt = "Open Saved Image"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        start {
            let folder = try self.makeSession("Saved Image")
            var image = source
            self.append("Source: \(source.path)\n")
            if source.pathExtension.lowercased() == "raw" {
                image = folder.appendingPathComponent("Card.img")
                self.status = "Opening saved card copy"
                try await self.run(self.helper("recovery-engine"),["reconstruct",source.path,image.path])
            }
            try await self.extract(image,folder:folder)
        }
    }
    func cancel() { cancelled = true; process?.terminate() }
}

struct ContentView: View {
    @StateObject private var model = ReaderModel()
    @State private var showDetails = false
    @State private var showCompatibility = false
    private let accent = Color(red:0.10,green:0.65,blue:0.60)
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:14) {
                if let iconURL = Bundle.main.url(forResource:"AppIcon",withExtension:"icns"), let icon = NSImage(contentsOf:iconURL) {
                    Image(nsImage:icon).resizable().scaledToFit().frame(width:52,height:52)
                }
                VStack(alignment:.leading,spacing:4) {
                    Text("Microtech USB Reader").font(.system(size:22,weight:.semibold))
                    Text("Import photos from SmartMedia and CompactFlash cards.").font(.system(size:13)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("Card stays unchanged",systemImage:"lock.shield").font(.system(size:11,weight:.medium)).foregroundStyle(accent)
            }.padding(.horizontal,24).padding(.vertical,16).fixedSize(horizontal:false,vertical:true)
            Divider()
            HStack(alignment:.top,spacing:0) {
                VStack(alignment:.leading,spacing:14) {
                        VStack(alignment:.leading,spacing:9) {
                            Text("Memory card").font(.system(size:13,weight:.semibold))
                            Picker("Card type",selection:$model.kind) { ForEach(CardKind.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().pickerStyle(.segmented)
                            Text(model.kind == .smartMedia ? "Lower slot · Gold contacts facing up" : "Upper slot · Connectors facing inward")
                                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                            Button(action:model.checkCard) { Label("Check Card",systemImage:"cable.connector") }
                                .buttonStyle(NextStepButtonStyle(highlighted:model.cardCheckResult?.succeeded != true))
                        }
                        Divider()
                        VStack(alignment:.leading,spacing:9) {
                            Text("Save photos to").font(.system(size:13,weight:.semibold))
                            HStack(alignment:.top,spacing:9) {
                                Image(systemName:"folder.fill").foregroundStyle(accent).font(.system(size:20))
                                VStack(alignment:.leading,spacing:3) {
                                    Text(model.destination.lastPathComponent).font(.system(size:13,weight:.medium)).lineLimit(2).truncationMode(.middle)
                                    Text(model.destination.deletingLastPathComponent().path.replacingOccurrences(of:NSHomeDirectory(),with:"~"))
                                        .font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                                }
                            }.frame(maxWidth:.infinity,alignment:.leading).padding(10)
                                .background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:9))
                                .help(model.destination.path)
                            Button("Choose Folder…",action:model.chooseDestination)
                        }
                        Divider()
                        VStack(alignment:.leading,spacing:10) {
                            Button(action:model.importPhotos) { Label("Import Photos",systemImage:"arrow.down.doc.fill") }
                                .buttonStyle(NextStepButtonStyle(highlighted:model.cardCheckResult?.succeeded == true))
                            Text("Photos stay on the card. Each import gets its own folder.")
                                .font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                        Divider()
                        Button("Open Saved Image…",systemImage:"externaldrive",action:model.importImage)
                            .help("Import photos from a saved card image instead of a connected reader.")
                    Spacer(minLength:0)
                }.padding(18).frame(width:280).frame(maxHeight:.infinity,alignment:.top).background(Color(nsColor:.underPageBackgroundColor).opacity(0.4)).disabled(model.busy)
                Divider()
                VStack(alignment:.leading,spacing:16) {
                    HStack {
                        VStack(alignment:.leading,spacing:6) {
                            Text(model.status).font(.system(size:19,weight:.semibold)).fixedSize(horizontal:false,vertical:true)
                            Text(model.detail).font(.system(size:13)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        }
                        Spacer()
                        if model.busy { Button("Stop",action:model.cancel) }
                    }
                    if model.busy {
                        if model.hasProgress { ProgressView(value:model.progress).tint(accent) }
                        else { ProgressView().controlSize(.small) }
                    }
                    if let error = model.error {
                        Label(error,systemImage:"exclamationmark.triangle").font(.system(size:12)).foregroundStyle(.orange)
                            .padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.orange.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
                    }
                    if let result = model.cardCheckResult {
                        CardCheckResultView(result:result)
                    } else if model.photos.isEmpty {
                        VStack(spacing:14) {
                            Image(systemName:"photo.on.rectangle.angled").font(.system(size:48,weight:.light)).foregroundStyle(accent.opacity(0.65))
                            Text("Your photos will appear here").font(.system(size:15,weight:.medium)).multilineTextAlignment(.center)
                            Text("Insert a card, then choose Import Photos.").font(.system(size:12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity).background(accent.opacity(0.035),in:RoundedRectangle(cornerRadius:16))
                    } else {
                        ScrollView {
                            LazyVGrid(columns:[GridItem(.adaptive(minimum:140))],spacing:14) {
                                ForEach(model.photos) { photo in
                                    Button { NSWorkspace.shared.open(photo.url) } label: {
                                        VStack(alignment:.leading,spacing:7) {
                                            Group { if let thumbnail = photo.thumbnail { Image(nsImage:thumbnail).resizable().scaledToFit() } else { Image(systemName:"film").font(.largeTitle) } }
                                                .frame(maxWidth:.infinity).frame(height:112).background(Color.black.opacity(0.05),in:RoundedRectangle(cornerRadius:8))
                                            Text(photo.url.lastPathComponent).font(.system(size:11,weight:.medium)).lineLimit(1)
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }.padding(2)
                        }
                    }
                    HStack {
                        Button("Open Photos",systemImage:"folder") { if let folder = model.photosFolder { NSWorkspace.shared.open(folder) } }.disabled(model.photos.isEmpty || model.busy)
                        Button("Open Import Folder",systemImage:"externaldrive") { if let folder = model.session { NSWorkspace.shared.open(folder) } }.disabled(model.session == nil)
                        Spacer()
                        Button(showDetails ? "Hide Details" : "Details") { showDetails.toggle() }
                    }
                    if showDetails {
                        ScrollView {
                            Text(model.log.isEmpty ? "Reader responses and import details appear here." : model.log)
                                .font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                                .frame(maxWidth:.infinity,alignment:.leading).padding(12)
                        }.frame(height:110).background(Color.black.opacity(0.03),in:RoundedRectangle(cornerRadius:8))
                    }
                }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
            }.frame(maxHeight:.infinity)
            Divider()
            HStack {
                Text("MicroTech DPCM-USB / CameraMate").font(.system(size:11)).foregroundStyle(.secondary)
                Spacer()
                Button("Compatibility") { showCompatibility.toggle() }.buttonStyle(.plain).font(.system(size:11)).foregroundStyle(.secondary)
                    .popover(isPresented:$showCompatibility) {
                        VStack(alignment:.leading,spacing:10) {
                            Text("Supported reader").font(.headline)
                            Text("MicroTech DPCM-USB / CameraMate (USB 07AF:0006).")
                            Text("Tested with 2 MB SmartMedia and 32 MB CompactFlash cards. Other SmartMedia capacities have not yet been tested.")
                        }.font(.system(size:12)).fixedSize(horizontal:false,vertical:true).padding(20).frame(width:300)
                    }
                Text("Version 1.6").font(.system(size:11)).foregroundStyle(.tertiary)
            }.padding(.horizontal,20).padding(.vertical,10).fixedSize(horizontal:false,vertical:true)
        }.frame(minWidth:900,minHeight:680,alignment:.top).background(Color(nsColor:.windowBackgroundColor))
            .onChange(of:model.kind) { _, _ in
                model.cardCheckResult = nil
                model.status = "Ready to import photos"
                model.detail = "Insert your \(model.kind.rawValue) card, then choose Check Card or Import Photos."
            }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in model.cancel() }
    }
}
@main struct MicrotechUSBReaderApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }.defaultSize(width:980,height:720).windowResizability(.contentMinSize)
            .commands { CommandGroup(replacing:.newItem) {} }
    }
}
