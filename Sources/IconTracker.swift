import AppKit
import ApplicationServices
import AVFoundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// One desktop icon, with the shape of its artwork.
struct DesktopIcon {
    /// Stable key for this item (its full file name).
    var id: String
    /// Name shown under the icon.
    var title: String
    /// Accessibility frame in CG global coordinates (top-left origin).
    var rect: CGRect
    /// Top surface of the artwork per 2 pt column, relative to `rect.minY`.
    /// This is why a folder gets its raised tab and a document gets a narrow
    /// page instead of a full-width slab.
    var profile: [Float]
    /// Horizontal offset of the first profile column from `rect.minX`.
    var xOffset: CGFloat
    var isFolder: Bool
}

/// Reads the Finder desktop icon frames through Accessibility.
///
/// The desktop is arranged by date added on this machine, so neither AppleScript
/// nor `.DS_Store` has per-icon positions. AX does expose the real frames.
final class IconTracker {
    static let shared = IconTracker()

    private(set) var icons: [DesktopIcon] = []
    private(set) var trusted = false

    /// 2 pt, matching `Platform.cell` in the simulation.
    static let cellPoints: CGFloat = 2

    private struct FileInfo {
        let path: String
        let name: String
        let displayName: String
        let isFolder: Bool
        let modified: Date
        let size: Int64
    }

    private struct Sheet {
        let profile: [Float]
        let xOffset: CGFloat
        let isFolder: Bool
    }

    private struct CachedSheet {
        let modified: Date
        let size: Int64
        let pointSize: CGFloat
        let sheet: Sheet
    }

    private var lastRefresh: CFTimeInterval = 0
    private var lastFileScan: CFTimeInterval = 0
    private var finderPID: pid_t = 0
    private var desktopFiles: [String: FileInfo] = [:]   // both full name and display name
    private var sheetCache: [String: CachedSheet] = [:]
    private var emptyRefreshes = 0
    private var didDump = false
    private var showIconPreview = true
    private var lastPreviewCheck: CFTimeInterval = 0

    private init() {}

    func refreshIfNeeded(now: CFTimeInterval) {
        // Fast enough that a dragged icon carries its snow with it.
        if now - lastRefresh < 0.2 { return }
        lastRefresh = now

        trusted = AXIsProcessTrusted()
        guard trusted else {
            if !icons.isEmpty { icons = [] }
            finderPID = 0
            return
        }

        if finderPID == 0 || NSRunningApplication(processIdentifier: finderPID) == nil {
            finderPID = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.finder")
                .first?.processIdentifier ?? 0
        }
        guard finderPID != 0 else { return }

        if now - lastFileScan >= 1.0 {
            loadDesktopFiles()
            lastFileScan = now
        }
        if now - lastPreviewCheck >= 10.0 {
            lastPreviewCheck = now
            loadPreviewSetting()
        }
        let app = AXUIElementCreateApplication(finderPID)
        var candidates: [String: DesktopIcon] = [:]

        // The desktop lives in a top-level scroll area. Restricting the walk to
        // those roots keeps icons from ordinary Finder windows out of the set.
        var roots: [AXUIElement] = []
        if let children = attr(app, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children where role(of: child) == "AXScrollArea" {
                roots.append(child)
            }
        }
        if roots.isEmpty { roots = [app] }

        for root in roots {
            walk(root, depth: 0, into: &candidates)
        }

        if candidates.isEmpty {
            clearAfterRepeatedEmptyResults()
            return
        }

        emptyRefreshes = 0
        icons = Array(candidates.values)
        if !didDump {
            didDump = true
            dumpDiagnostics()
        }
    }

    private func clearAfterRepeatedEmptyResults() {
        emptyRefreshes += 1
        if emptyRefreshes >= 5 && !icons.isEmpty {
            icons = []
        }
    }

    // MARK: - Files

    private func loadDesktopFiles() {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop")
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey
        ]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys)
        ) else { return }

        var map: [String: FileInfo] = [:]
        for item in items {
            let values = try? item.resourceValues(forKeys: keys)
            let isDir = values?.isDirectory ?? false
            let isPackage = values?.isPackage ?? false
            let modified = values?.contentModificationDate ?? .distantPast
            let size = Int64(values?.fileSize ?? 0)
            let name = item.lastPathComponent
            guard !name.hasPrefix(".") else { continue }
            let info = FileInfo(
                path: item.path,
                name: name,
                displayName: item.deletingPathExtension().lastPathComponent,
                isFolder: isDir && !isPackage,
                modified: modified,
                size: size
            )
            map[name] = info
            if map[info.displayName] == nil {
                map[info.displayName] = info
            }
        }
        desktopFiles = map
    }

    private func loadPreviewSetting() {
        guard let domain = UserDefaults.standard.persistentDomain(forName: "com.apple.finder"),
              let view = domain["DesktopViewSettings"] as? [String: Any],
              let icon = view["IconViewSettings"] as? [String: Any],
              let show = icon["showIconPreview"] as? Bool else { return }
        if show != showIconPreview {
            showIconPreview = show
            sheetCache.removeAll()
        }
    }

    // MARK: - AX walk

    private func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(e, name as CFString, &v)
        return err == .success ? v : nil
    }

    private func role(of e: AXUIElement) -> String {
        attr(e, kAXRoleAttribute) as? String ?? ""
    }

    private func frame(of e: AXUIElement) -> CGRect {
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let pv = attr(e, kAXPositionAttribute) {
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        }
        if let sv = attr(e, kAXSizeAttribute) {
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    private func walk(_ e: AXUIElement, depth: Int, into out: inout [String: DesktopIcon]) {
        if depth > 10 { return }

        let title = attr(e, kAXTitleAttribute) as? String ?? ""
        if !title.isEmpty {
            let rect = frame(of: e)
            let plausible = rect.width >= 16 && rect.height >= 16
                && rect.width <= 320 && rect.height <= 320
                && rect.minX > -30000 && rect.minY > -30000

            if let info = fileInfo(for: e, title: title),
               plausible, let sheet = sheet(for: info, pointSize: rect.width) {
                let icon = DesktopIcon(
                    id: info.name,
                    title: title,
                    rect: rect,
                    profile: sheet.profile,
                    xOffset: sheet.xOffset,
                    isFolder: sheet.isFolder
                )
                // Keep the most compact element for each file: that is the icon
                // image itself rather than the surrounding cell.
                if let existing = out[info.name] {
                    if rect.height < existing.rect.height {
                        out[info.name] = icon
                    }
                } else {
                    out[info.name] = icon
                }
            } else if plausible, role(of: e) == "AXImage" {
                // Finder can expose an icon/stack without a resolvable file
                // path (stacks, aliases, restricted Desktop access). Fall back
                // to a shallow flat cap so the snow still gathers on it.
                let cells = max(2, Int((rect.width / IconTracker.cellPoints).rounded()))
                let profile = [Float](repeating: 6, count: cells)
                let icon = DesktopIcon(
                    id: "ax:" + title,
                    title: title,
                    rect: rect,
                    profile: profile,
                    xOffset: 0,
                    isFolder: false
                )
                if let existing = out[icon.id] {
                    if rect.height < existing.rect.height {
                        out[icon.id] = icon
                    }
                } else {
                    out[icon.id] = icon
                }
            }
        }

        if depth < 10, let children = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
            for c in children.prefix(400) {
                walk(c, depth: depth + 1, into: &out)
            }
        }
    }

    /// Resolve the real file behind a Finder desktop AX element. Finder exposes
    /// an AXURL (sometimes a file-reference URL) and AXFilename, so icon snow
    /// still works when the Desktop folder itself is not readable by the app.
    private func fileInfo(for element: AXUIElement, title: String) -> FileInfo? {
        if let url = axFileURL(of: element) {
            let path = url.path
            if FileManager.default.fileExists(atPath: path) {
                return makeFileInfo(url: url)
            }
        }
        if let filename = attr(element, "AXFilename") as? String, !filename.isEmpty {
            let path = NSHomeDirectory() + "/Desktop/" + filename
            if FileManager.default.fileExists(atPath: path) {
                return makeFileInfo(url: URL(fileURLWithPath: path))
            }
        }
        return desktopFiles[title] ?? fuzzyMatch(title)
    }

    private func axFileURL(of element: AXUIElement) -> URL? {
        guard let value = attr(element, "AXURL"),
              CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        let cfURL = value as! CFURL
        if let pathURL = CFURLCreateFilePathURL(kCFAllocatorDefault, cfURL, nil) {
            return pathURL.takeRetainedValue() as URL
        }
        return nil
    }

    private func makeFileInfo(url: URL) -> FileInfo {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey
        ]
        let values = try? url.resourceValues(forKeys: keys)
        return FileInfo(
            path: url.path,
            name: url.lastPathComponent,
            displayName: url.deletingPathExtension().lastPathComponent,
            isFolder: (values?.isDirectory ?? false) && !(values?.isPackage ?? false),
            modified: values?.contentModificationDate ?? .distantPast,
            size: Int64(values?.fileSize ?? 0)
        )
    }

    /// Finder sometimes elides long names. Match the visible part.
    private func fuzzyMatch(_ title: String) -> FileInfo? {
        let trimmed = title.replacingOccurrences(of: "…", with: "")
        guard trimmed.count >= 4 else { return nil }
        for info in desktopFiles.values {
            if info.displayName.hasPrefix(trimmed) || info.name.hasPrefix(trimmed) {
                return info
            }
        }
        return nil
    }

    // MARK: - Artwork silhouette

    /// Finder draws images and movies as a white "picture frame" around the
    /// thumbnail. NSWorkspace only hands back the generic document icon for
    /// those, so build the frame from the media's aspect ratio instead.
    private func previewSheet(for info: FileInfo, pointSize: CGFloat) -> Sheet? {
        guard showIconPreview else { return nil }
        let ext = (info.name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return nil }
        let isImage = type.conforms(to: .image)
        let isMovie = type.conforms(to: .movie) || type.conforms(to: .video)
        guard isImage || isMovie else { return nil }

        var aspect: CGFloat?
        if isImage {
            if let src = CGImageSourceCreateWithURL(
                URL(fileURLWithPath: info.path) as CFURL, nil
            ), let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
                as? [CFString: Any] {
                let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
                let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
                if w > 0 && h > 0 { aspect = CGFloat(w / h) }
            }
        } else {
            let asset = AVURLAsset(url: URL(fileURLWithPath: info.path))
            if let track = asset.tracks(withMediaType: .video).first {
                let size = track.naturalSize.applying(track.preferredTransform)
                let w = abs(size.width)
                let h = abs(size.height)
                if w > 0 && h > 0 { aspect = w / h }
            }
        }
        guard let aspect else { return nil }

        // The preview art is fitted into a square, then given a white border.
        let innerMax = pointSize * 0.844
        let border = pointSize * 0.04
        let innerW = aspect >= 1 ? innerMax : innerMax * aspect
        let innerH = aspect >= 1 ? innerMax / aspect : innerMax
        let outerW = innerW + border * 2
        let outerH = innerH + border * 2
        let xOffset = (pointSize - outerW) * 0.5
        let yOffset = (pointSize - outerH) * 0.5

        let cells = max(2, Int((outerW / IconTracker.cellPoints).rounded()))
        var profile = [Float](repeating: Float(yOffset), count: cells)
        if cells > 1 {
            // The white frame has softly rounded corners.
            profile[0] += 0.5
            profile[cells - 1] += 0.5
        }
        return Sheet(profile: profile, xOffset: xOffset, isFolder: false)
    }

    /// Renders the file's real icon and measures its alpha silhouette. The
    /// desktop icon is drawn at the same size and position as the AX frame, so
    /// these offsets line up exactly with what is on screen.
    private func sheet(for info: FileInfo, pointSize: CGFloat) -> Sheet? {
        if let cached = sheetCache[info.path],
           cached.modified == info.modified,
           cached.size == info.size,
           abs(cached.pointSize - pointSize) < 0.5 {
            return cached.sheet
        }

        let points = max(16, pointSize)
        let pixels = max(32, Int((points * 2).rounded()))

        if let preview = previewSheet(for: info, pointSize: points) {
            sheetCache[info.path] = CachedSheet(
                modified: info.modified, size: info.size,
                pointSize: points, sheet: preview
            )
            return preview
        }

        let image = NSWorkspace.shared.icon(forFile: info.path)
        image.size = NSSize(width: CGFloat(pixels), height: CGFloat(pixels))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: CGFloat(pixels), height: CGFloat(pixels))

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)))
        NSGraphicsContext.restoreGraphicsState()

        // Row 0 is the top row for NSBitmapImageRep. Threshold out the soft
        // shadow so snow sits on solid artwork, not its drop shadow.
        var top = [Int](repeating: pixels, count: pixels)
        var minX = pixels
        var maxX = -1
        for y in 0..<pixels {
            for x in 0..<pixels {
                let alpha = rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
                if alpha > 0.45 {
                    if y < top[x] { top[x] = y }
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
            }
        }
        guard maxX >= 0, maxX - minX >= 4 else { return nil }

        let pxPerPoint = CGFloat(pixels) / points
        let cellPx = max(2, Int((IconTracker.cellPoints * pxPerPoint).rounded()))
        var firstCell = minX / cellPx
        var lastCell = maxX / cellPx

        func cellTop(_ cell: Int) -> Int? {
            let x0 = cell * cellPx
            let x1 = min(pixels, x0 + cellPx)
            var best = pixels
            for x in x0..<x1 where top[x] < best { best = top[x] }
            return best == pixels ? nil : best
        }

        // Trim cells at either end that contain no solid artwork.
        while firstCell < lastCell, cellTop(firstCell) == nil { firstCell += 1 }
        while lastCell > firstCell, cellTop(lastCell) == nil { lastCell -= 1 }

        var profile: [Float] = []
        profile.reserveCapacity(lastCell - firstCell + 1)
        for cell in firstCell...lastCell {
            let best: Int
            if let t = cellTop(cell) {
                best = t
            } else {
                // A gap inside the silhouette: bridge it with the lower
                // neighbouring surface rather than floating snow in the air.
                best = cellTop(cell - 1) ?? cellTop(cell + 1) ?? 0
            }
            let pt = Float(CGFloat(best) / pxPerPoint) - 0.5
            profile.append(max(0, pt))
        }

        let sheet = Sheet(
            profile: profile,
            xOffset: CGFloat(firstCell * cellPx) / pxPerPoint,
            isFolder: info.isFolder
        )
        sheetCache[info.path] = CachedSheet(
            modified: info.modified, size: info.size,
            pointSize: points, sheet: sheet
        )
        return sheet
    }

    // MARK: - Diagnostic

    private func dumpDiagnostics() {
        var out = "AX trusted\n"
        for icon in icons {
            let lo = icon.profile.min() ?? 0
            let hi = icon.profile.max() ?? 0
            out += "\(icon.title) rect=\(Int(icon.rect.minX)),\(Int(icon.rect.minY)) "
            out += "\(Int(icon.rect.width))x\(Int(icon.rect.height)) "
            out += "cells=\(icon.profile.count) top=\(lo)..\(hi) folder=\(icon.isFolder)\n"
        }
        try? out.write(toFile: "/tmp/snow_icons.txt", atomically: true, encoding: .utf8)
    }
}
