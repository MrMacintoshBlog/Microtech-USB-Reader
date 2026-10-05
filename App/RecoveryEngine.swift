// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import CryptoKit
import ImageIO

struct RescueError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
func ensure(_ test: Bool, _ message: String) throws {
    if !test { throw RescueError(message) }
}
func saveNew(_ data: Data, to url: URL) throws {
    try ensure(!FileManager.default.fileExists(atPath: url.path), "Output already exists: \(url.lastPathComponent)")
    try data.write(to: url, options: .withoutOverwriting)
}
func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
// FAT stores camera-local wall-clock time without a timezone. Use the Mac's
// current timezone unless the embedded photo date provides its own UTC offset.
func validatedDate(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, zone: TimeZone) -> Date? {
    guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
          (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
    var calendar = Calendar(identifier:.gregorian); calendar.timeZone = zone
    let parts = DateComponents(year:year,month:month,day:day,hour:hour,minute:minute,second:second)
    guard let date = calendar.date(from:parts) else { return nil }
    let actual = calendar.dateComponents([.year,.month,.day,.hour,.minute,.second],from:date)
    guard actual.year == year, actual.month == month, actual.day == day,
          actual.hour == hour, actual.minute == minute, actual.second == second else { return nil }
    return date
}
func fatDate(_ entries: Data, at o: Int, creation: Bool) -> Date? {
    func word(_ relative: Int) -> Int { Int(entries[o+relative]) | Int(entries[o+relative+1]) << 8 }
    let date = word(creation ? 16 : 24), time = word(creation ? 14 : 22)
    guard date != 0 else { return nil }
    let fraction = creation ? Int(entries[o+13]) : 0
    guard fraction <= 199, let result = validatedDate(year:1980+(date >> 9),month:(date >> 5)&15,day:date&31,
        hour:time >> 11,minute:(time >> 5)&63,second:(time&31)*2+fraction/100,zone:.current) else { return nil }
    return result.addingTimeInterval(Double(fraction%100)/100)
}
func photoDate(_ properties: [String:Any]?) -> Date? {
    guard let exif = properties?[kCGImagePropertyExifDictionary as String] as? [String:Any],
          let text = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
    // Reject zero dates and impossible calendar values instead of normalizing them.
    let characters = Array(text)
    guard characters.count == 19, characters[4] == ":", characters[7] == ":", characters[10] == " ",
          characters[13] == ":", characters[16] == ":" else { return nil }
    let fields = text.split(whereSeparator:{ ": ".contains($0) })
    guard fields.count == 6, fields.map(String.init).map({ $0.count }) == [4,2,2,2,2,2],
          fields.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return nil }
    let n = fields.compactMap { Int($0) }
    guard n.count == 6, n[0] >= 1900 else { return nil }
    var zone = TimeZone.current
    if let offset = exif["OffsetTimeOriginal"] as? String, offset.count == 6 {
        let characters = Array(offset)
        if (characters[0] == "+" || characters[0] == "-"), characters[3] == ":",
           let hours = Int(String(characters[1...2])), let minutes = Int(String(characters[4...5])),
           hours <= 23, minutes <= 59,
           let explicit = TimeZone(secondsFromGMT:(characters[0] == "-" ? -1 : 1)*(hours*3600+minutes*60)) { zone = explicit }
    }
    return validatedDate(year:n[0],month:n[1],day:n[2],hour:n[3],minute:n[4],second:n[5],zone:zone)
}
func preserveDates(_ entries: Data, at o: Int, properties: [String:Any]?, file: URL) -> [String:Any] {
    let embedded = photoDate(properties)
    let cardCreated = fatDate(entries,at:o,creation:true), cardModified = fatDate(entries,at:o,creation:false)
    let created = cardCreated ?? embedded, modified = cardModified ?? embedded
    let importedCreation = (try? FileManager.default.attributesOfItem(atPath:file.path)[.creationDate]) as? Date
    var attributes = [FileAttributeKey:Any]()
    var result: [String:Any] = ["creationDateSource":cardCreated != nil ? "card" : embedded != nil ? "photo" : "import",
                              "modificationDateSource":cardModified != nil ? "card" : embedded != nil ? "photo" : "import",
                              "cardDateTimezone":TimeZone.current.identifier]
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
    if let date = embedded { result["embeddedPhotoDate"] = formatter.string(from:date) }
    if let date = created { attributes[.creationDate] = date; result["originalCreationDate"] = formatter.string(from:date) }
    if let date = modified { attributes[.modificationDate] = date; result["originalModificationDate"] = formatter.string(from:date) }
    if !attributes.isEmpty {
        do {
            // Setting an older modification date can also move the creation date
            // on macOS. Restore the intended creation date after setting modification.
            if let date = modified { try FileManager.default.setAttributes([.modificationDate:date],ofItemAtPath:file.path) }
            if let date = created ?? importedCreation { try FileManager.default.setAttributes([.creationDate:date],ofItemAtPath:file.path) }
        }
        catch { result["dateWarning"] = "Photo copied, but file dates could not be set: \(error.localizedDescription)"; print("Date warning: \(file.lastPathComponent)") }
    }
    return result
}

func reconstruct(_ source: URL, _ target: URL) throws {
    let raw = try Data(contentsOf: source)
    let geometries = [(1,256,16),(2,256,16),(4,512,16),(8,512,16),(16,512,32),(32,512,32),(64,512,32),(128,512,32)]
    guard let g = geometries.first(where: { $0.0 * 1048576 / $0.1 * ($0.1 + 64) == raw.count }) else {
        throw RescueError("This raw capture has an unsupported or incomplete size. Keep it for diagnosis.")
    }
    let (mb, pageSize, pagesPerBlock) = g
    let stride = pageSize + 64, blockSize = pageSize * pagesPerBlock
    let physicalBlocks = mb * 1048576 / blockSize, logicalBlocks = physicalBlocks * 125 / 128
    var image = Data(repeating: 0, count: logicalBlocks * blockSize)
    var map = [Int: Int](), conflicts = [String]()
    for pba in 0..<physicalBlocks {
        let o = pba * pagesPerBlock * stride + pageSize
        let spare = raw[o..<o+16]
        guard spare.prefix(6).allSatisfy({ $0 == 255 }), raw[o+6] >> 4 == 1,
              (raw[o+6] ^ raw[o+7]).nonzeroBitCount % 2 == 0 else { continue }
        let local = ((Int(raw[o+6]) << 8 | Int(raw[o+7])) & 0x7ff) >> 1
        guard local < 1000 else { continue }
        let lba = local + (pba / 1024) * 1000
        guard lba < logicalBlocks else { continue }
        if let old = map[lba] { conflicts.append("Logical block \(lba): physical \(old), \(pba)"); continue }
        map[lba] = pba
        for page in 0..<pagesPerBlock {
            let start = (pba * pagesPerBlock + page) * stride
            let dest = lba * blockSize + page * pageSize
            image.replaceSubrange(dest..<dest+pageSize, with: raw[start..<start+pageSize])
        }
    }
    let report: [String: Any] = ["capacityMiB": mb, "pageBytes": pageSize, "physicalBlocks": physicalBlocks,
        "mappedBlocks": map.count, "rawSHA256": digest(raw), "imageSHA256": digest(image),
        "mapping": Dictionary(uniqueKeysWithValues: map.map { (String($0.key), $0.value) }), "conflicts": conflicts,
        "unmappedLogicalBlocks": (0..<logicalBlocks).filter { map[$0] == nil },
        "notes": "Unmapped logical blocks are zero-filled. Original pages remain in the raw capture. No ECC correction or deleted-file carving is performed."]
    try saveNew(JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), to: target.deletingPathExtension().appendingPathExtension("map.json"))
    try ensure(conflicts.isEmpty, "The card has ambiguous block mappings. The raw backup is saved; automatic extraction stopped to preserve those alternatives.")
    try ensure(map[0] != nil, "The card's starting block could not be mapped. The raw backup is saved for further recovery.")
    try saveNew(image, to: target)
    print("Reconstructed \(mb) MB SmartMedia: \(map.count) logical blocks; image SHA-256 \(digest(image))")
}

struct FATVolume {
    let data: Data
    let start: Int, bps: Int, spc: Int, fatStart: Int, rootStart: Int, rootEntries: Int
    let dataStart: Int, clusterCount: Int, bits: Int, rootCluster: Int
    init(_ data: Data) throws {
        self.data = data
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o+2) << 16 }
        try ensure(data.count >= 512, "The image is too small.")
        var boot = 0
        // A plausible FAT boot sector has a valid bytes-per-sector field.
        if ![512,1024,2048,4096].contains(u16(11)) {
            try ensure(data[510] == 0x55 && data[511] == 0xaa, "No FAT boot sector or partition table found.")
            guard let partition = (0..<4).first(where: { [1,4,6,11,12,14].contains(Int(data[446+$0*16+4])) }) else {
                throw RescueError("No supported FAT partition found. The disk image remains saved.")
            }
            boot = u32(446 + partition*16 + 8) * 512
        }
        try ensure(boot >= 0 && boot + 512 <= data.count, "Partition starts outside the saved image.")
        start = boot; bps = u16(boot+11); spc = Int(data[boot+13])
        let reserved = u16(boot+14), fats = Int(data[boot+16])
        rootEntries = u16(boot+17)
        let sectors = u16(boot+19) == 0 ? u32(boot+32) : u16(boot+19)
        let fatSectors = u16(boot+22) == 0 ? u32(boot+36) : u16(boot+22)
        try ensure([512,1024,2048,4096].contains(bps) && spc > 0 && spc.nonzeroBitCount == 1 && reserved > 0 && fats > 0 && fatSectors > 0, "Invalid FAT geometry.")
        let rootSectors = (rootEntries * 32 + bps - 1) / bps
        let firstDataSector = reserved + fats * fatSectors + rootSectors
        try ensure(sectors > firstDataSector && boot + sectors * bps <= data.count, "The FAT partition is incomplete.")
        fatStart = boot + reserved*bps
        rootStart = boot + (reserved + fats*fatSectors)*bps
        dataStart = boot + firstDataSector*bps
        clusterCount = (sectors - firstDataSector) / spc
        bits = clusterCount < 4085 ? 12 : clusterCount < 65525 ? 16 : 32
        rootCluster = bits == 32 ? u32(boot+44) : 0
        try ensure(fatStart < dataStart && dataStart <= data.count, "FAT offsets are invalid.")
    }
    func next(_ cluster: Int) throws -> Int {
        let offset = fatStart + (bits == 12 ? cluster * 3 / 2 : cluster * (bits / 8))
        try ensure(offset >= fatStart && offset + (bits == 32 ? 4 : 2) <= rootStart, "Cluster address exceeds the FAT.")
        var n = Int(data[offset]) | Int(data[offset+1]) << 8
        if bits == 12 { n = cluster % 2 == 0 ? n & 0xfff : n >> 4 }
        if bits == 32 { n = (n | Int(data[offset+2]) << 16 | Int(data[offset+3]) << 24) & 0x0fffffff }
        return n
    }
    func chain(_ first: Int, size: Int? = nil) throws -> Data {
        if size == 0 { return Data() }
        var result = Data(), visited = Set<Int>(), cluster = first
        let eof = bits == 12 ? 0xff8 : bits == 16 ? 0xfff8 : 0xffffff8
        while cluster < eof {
            try ensure(cluster >= 2 && cluster < clusterCount+2 && visited.insert(cluster).inserted, "A file has an invalid or looping cluster chain.")
            let o = dataStart + (cluster-2)*bps*spc, length = bps*spc
            try ensure(o >= dataStart && o+length <= data.count, "File data exceeds the image.")
            result.append(data[o..<o+length])
            if let size = size, result.count >= size { return result.prefix(size) }
            cluster = try next(cluster)
        }
        if let size = size { try ensure(result.count >= size, "A file is truncated in the FAT chain.") }
        return result
    }
    func extract(to folder: URL) throws -> [[String: Any]] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var records = [[String: Any]](), seenDirectories = Set<Int>()
        let photoExtensions = Set(["jpg","jpeg","tif","tiff","png","bmp","gif","mov","avi","mp4","qt"])
        func walk(_ entries: Data, _ path: URL, _ depth: Int) throws {
            try ensure(depth <= 24, "Directory nesting exceeds the recovery limit.")
            for o in stride(from: 0, through: max(0,entries.count-32), by: 32) {
                guard o+32 <= entries.count else { break }
                if entries[o] == 0 { break }
                if entries[o] == 0xe5 { continue }
                let attr = entries[o+11]
                if attr == 15 || attr & 8 != 0 { continue }
                let name = String(bytes: entries[o..<o+8], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
                let ext = String(bytes: entries[o+8..<o+11], encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? ""
                if name.isEmpty || name == "." || name == ".." { continue }
                let safe = (ext.isEmpty ? name : name+"."+ext).map { "/:\\".contains($0) ? "_" : $0 }
                let dest = path.appendingPathComponent(String(safe))
                let cluster = Int(entries[o+26]) | Int(entries[o+27]) << 8 | (bits == 32 ? (Int(entries[o+20]) | Int(entries[o+21]) << 8) << 16 : 0)
                if attr & 16 != 0 {
                    try ensure(seenDirectories.insert(cluster).inserted, "Duplicate or looping directory detected.")
                    try walk(chain(cluster), dest, depth+1)
                } else if photoExtensions.contains(ext.lowercased()) {
                    let size = Int(entries[o+28]) | Int(entries[o+29]) << 8 | Int(entries[o+30]) << 16 | Int(entries[o+31]) << 24
                    let content = try chain(cluster,size:size)
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                    try saveNew(content,to:dest)
                    var record: [String: Any] = ["file": dest.path, "bytes": size, "sha256": digest(content)]
                    let source = CGImageSourceCreateWithData(content as CFData,nil)
                    let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0,0,nil) as? [String:Any] }
                    record.merge(preserveDates(entries,at:o,properties:properties,file:dest)) { _, new in new }
                    if ["jpg","jpeg","png","tif","tiff","bmp","gif"].contains(ext.lowercased()) {
                        let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary) }
                        record["decodes"] = decoded != nil
                        if let image = decoded { record["width"] = image.width; record["height"] = image.height }
                        if let properties = properties,
                           let exif = properties[kCGImagePropertyExifDictionary as String] as? [String:Any],
                           let bpp = exif[kCGImagePropertyExifCompressedBitsPerPixel as String] { record["compressedBitsPerPixel"] = bpp }
                    }
                    records.append(record)
                    print("Copied \(dest.lastPathComponent) (\(size) bytes)")
                }
            }
        }
        let root = bits == 32 ? try chain(rootCluster) : data.subdata(in: rootStart..<rootStart+rootEntries*32)
        try walk(root,folder,0)
        return records
    }
}

do {
    let args = CommandLine.arguments
    try ensure(args.count == 4, "Usage: recovery-engine reconstruct raw image | extract image photos-folder")
    let source = URL(fileURLWithPath:args[2]), target = URL(fileURLWithPath:args[3])
    if args[1] == "reconstruct" { try reconstruct(source,target) }
    else if args[1] == "extract" {
        let data = try Data(contentsOf:source), volume = try FATVolume(data)
        let files = try volume.extract(to:target)
        let report: [String:Any] = ["imageSHA256": digest(data), "fatType": "FAT\(volume.bits)", "files": files,
            "fileCount": files.count, "datePreservationWarnings": files.filter { $0["dateWarning"] != nil }.count, "decodeFailures": files.filter { ($0["decodes"] as? Bool) == false }.count,
            "notes": "Existing photo and video files copied using short FAT filenames. Deleted files are not carved. The saved image is never modified."]
        try saveNew(JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),to:target.deletingLastPathComponent().appendingPathComponent("photos-report.json"))
        print("EXTRACTED: \(files.count) photo/video files from FAT\(volume.bits)")
    } else { throw RescueError("Unknown command") }
} catch { fputs("Import stopped: \(error.localizedDescription)\n",stderr); exit(1) }
