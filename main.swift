import SwiftUI
import Translation
import Vision
import AppKit
import Carbon
import CoreGraphics
import Combine
import AVFoundation

func debugLog(_ message: String) {
    let path = "/tmp/snaptrans_debug.log"
    let line = "[\(Date())] \(message)\n"
    let manager = FileManager.default
    if manager.fileExists(atPath: path),
       let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8) ?? Data())
        try? handle.close()
    } else {
        manager.createFile(atPath: path, contents: line.data(using: .utf8))
    }
}

// MARK: - 发音朗读（系统语音合成，完全离线）

final class SpeechService {
    enum Accent: String {
        case us = "en-US"
        case uk = "en-GB"

        var label: String { self == .us ? "美" : "英" }
        /// 优先使用的语音名（系统自带、增强音质）
        var preferredVoiceName: String { self == .us ? "Samantha" : "Daniel" }
        var tip: String { self == .us ? "美式发音" : "英式发音" }
    }

    static let shared = SpeechService()
    private let synthesizer = AVSpeechSynthesizer()

    private init() {
        debugLog("语音服务已就绪，可用语音 \(AVSpeechSynthesisVoice.speechVoices().count) 个")
    }

    /// 读一段文本（英文单词或句子）
    func speak(_ text: String, accent: Accent) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 先停掉正在读的，避免叠音
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        // 优先挑指定口音下音质最好的那个语音，找不到就退回该语言的默认语音
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == accent.rawValue }
        let voice = candidates.first { $0.name == accent.preferredVoiceName }
            ?? AVSpeechSynthesisVoice(language: accent.rawValue)
            ?? candidates.first
        utterance.voice = voice
        utterance.rate = 0.42   // 略慢，适合听清发音
        utterance.volume = 1.0
        debugLog("朗读：\(text) 口音=\(accent.rawValue) 语音=\(voice?.name ?? "默认")")
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}

let accentKey = "snaptranslate.accent"

/// 记住上次选的口音（默认美音）
func preferredAccent() -> SpeechService.Accent {
    let raw = UserDefaults.standard.string(forKey: accentKey) ?? SpeechService.Accent.us.rawValue
    return raw == SpeechService.Accent.uk.rawValue ? .uk : .us
}

func rememberAccent(_ accent: SpeechService.Accent) {
    UserDefaults.standard.set(accent.rawValue, forKey: accentKey)
}

// MARK: - 翻译状态

final class TranslateState: ObservableObject {
    @Published var sourceText: String = ""
    @Published var resultText: String = ""
    @Published var isLoading: Bool = true
    @Published var engine: String = ""

    // 词典模式（识别的是单个英文单词时）
    @Published var isWordMode: Bool = false
    @Published var dictionaryEntry: LocalDictEntry?
}

// MARK: - 屏幕文字识别

func extractText(from imagePath: String) -> String {
    guard let image = NSImage(contentsOfFile: imagePath),
          let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = [currentSourceOption().visionCode]
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    guard (try? handler.perform([request])) != nil else { return "" }

    let sorted = (request.results ?? []).sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
    let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
        .filter { line in
            line.filter { $0.isLetter || $0.isNumber }.count >= 2
        }
    return lines.joined(separator: "\n")
}

func extractText(fromImageData data: Data) -> String {
    let path = NSTemporaryDirectory() + "snaptrans-clip-\(UUID().uuidString).png"
    try? data.write(to: URL(fileURLWithPath: path))
    let text = extractText(from: path)
    try? FileManager.default.removeItem(atPath: path)
    return text
}

// MARK: - 在线翻译兜底

/// 当前语言对应的在线翻译源（延迟构造，避免全局初始化时访问 UserDefaults）
func currentOnlineSources() -> [(base: String, kind: String)] {
    let src = currentSourceOption().myMemoryCode
    let tgt = currentTargetOption().myMemoryCode
    return [
        ("https://api.mymemory.translated.net/get?langpair=\(src)%7C\(tgt)&q=", "memory"),
        ("https://translate.googleapis.com/translate_a/single?client=gtx&sl=\(src)&tl=\(tgt)&dt=t&q=", "google")
    ]
}

/// 把长文本切成小块，避免超过在线接口的单次长度限制
func splitIntoChunks(_ text: String, limit: Int = 420) -> [String] {
    var chunks: [String] = []
    var current = ""
    for line in text.components(separatedBy: "\n") {
        if current.count + line.count + 1 > limit, !current.isEmpty {
            chunks.append(current)
            current = line
        } else {
            current = current.isEmpty ? line : current + "\n" + line
        }
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
}

func requestSingleChunk(_ text: String, completion: @escaping (String?) -> Void) {
    guard let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
        completion(nil)
        return
    }

    let sources = currentOnlineSources()

    func attempt(_ index: Int) {
        guard index < sources.count else {
            debugLog("所有在线源都失败")
            completion(nil)
            return
        }
        guard let url = URL(string: sources[index].base + query) else { attempt(index + 1); return }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            debugLog("在线源\(index)（\(sources[index].kind)）错误=\(error?.localizedDescription ?? "无")，状态码=\((response as? HTTPURLResponse)?.statusCode ?? 0)")

            var translated: String?
            if let data = data {
                if sources[index].kind == "memory" {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let status = json["responseStatus"] as? Int,
                       status == 200,
                       let responseData = json["responseData"] as? [String: Any],
                       let value = responseData["translatedText"] as? String,
                       !value.isEmpty {
                        translated = value
                    } else {
                        debugLog("在线源\(index) 内容异常：\(String(data: data, encoding: .utf8)?.prefix(150) ?? "")")
                    }
                } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [Any],
                          let lines = obj.first as? [Any] {
                    var combined = ""
                    for item in lines {
                        if let arr = item as? [Any], let piece = arr.first as? String {
                            combined += piece
                        }
                    }
                    if !combined.isEmpty { translated = combined }
                }
            }

            if let translated = translated {
                completion(translated)
            } else {
                attempt(index + 1)
            }
        }.resume()
    }

    attempt(0)
}

func onlineTranslate(text: String, completion: @escaping (String?) -> Void) {
    let chunks = splitIntoChunks(text)
    guard !chunks.isEmpty else { completion(nil); return }
    if chunks.count == 1 {
        requestSingleChunk(chunks[0], completion: completion)
        return
    }

    func step(_ index: Int, accumulated: [String]) {
        if index >= chunks.count {
            completion(accumulated.joined(separator: "\n"))
            return
        }
        requestSingleChunk(chunks[index]) { piece in
            guard let piece = piece else { completion(nil); return }
            step(index + 1, accumulated: accumulated + [piece])
        }
    }

    step(0, accumulated: [])
}

// MARK: - 结果浮窗

struct ResultPanelView: View {
    @ObservedObject var state: TranslateState
    @ObservedObject var vocabulary: VocabularyStore
    @State private var copiedHint: String?
    @State private var showSource: Bool = false
    @State private var toast: String?

    var onClose: () -> Void
    var onRetryOnline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 4)
            content
            Divider().padding(.horizontal, 4)
            footer
        }
        .padding(.vertical, 12)
        .frame(minWidth: 280, maxWidth: 500)
        // 直接用「圆角形状 + 材质填充」，避免「矩形材质再裁剪」导致的直角残留。
        // 阴影不在 SwiftUI 层画（会被 panel frame 硬切成直角），交给系统窗口层（panel.hasShadow）。
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        // 面板内的提示浮层（加生词本时显示，不跑到屏幕别处）
        .overlay(alignment: .top) {
            if let toast = toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
        .translateCompat(
            text: state.isWordMode ? "" : state.sourceText,
            onResult: { result in
                state.resultText = result
                state.engine = "系统翻译"
                state.isLoading = false
            },
            onUnavailable: { startOnlineFallback() }
        )
        .onExitCommand(perform: onClose)
    }

    // MARK: 顶部
    private var header: some View {
        HStack(spacing: 8) {
            LanguageBadge(text: currentSourceOption().shortName)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            LanguageBadge(text: currentTargetOption().shortName)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: 中间内容
    @ViewBuilder
    private var content: some View {
        if state.isLoading {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(state.isWordMode ? "正在查词典…" : "正在翻译…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        } else if state.isWordMode, let entry = state.dictionaryEntry {
            dictionaryContent(entry)
        } else if state.resultText.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("暂时没翻译出来")
                    .font(.system(size: 14, weight: .medium))
                Text("网络可能不稳定，或系统翻译暂不支持。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("用在线翻译再试一次", action: onRetryOnline)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(state.resultText)
                    .font(.system(size: 16, weight: .semibold))
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                // 原文单词（点一下加入生词本，再点取消）
                let words = extractWords(from: state.sourceText)
                if !words.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(words, id: \.self) { word in
                            WordChip(word: word, added: vocabulary.contains(word)) {
                                if vocabulary.contains(word) {
                                    vocabulary.remove(word)
                                    showToast("已从生词本移除")
                                } else {
                                    vocabulary.add(word: word, context: state.sourceText)
                                    showToast("「\(word)」已加入生词本")
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                }

                // 原文（可展开）
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showSource.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showSource ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text(showSource ? "收起原文" : "查看原文")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showSource {
                    Text(state.sourceText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    // MARK: 词典内容（单个单词，来自内置本地词典）
    @ViewBuilder
    private func dictionaryContent(_ entry: LocalDictEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 单词 + 音标
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(entry.word.capitalized)
                    .font(.system(size: 22, weight: .bold))
                if let phonetic = entry.phonetic, !phonetic.isEmpty {
                    Text("[\(phonetic)]")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // 发音（美音 / 英音）
                SpeakButton(text: entry.word, accent: .us)
                SpeakButton(text: entry.word, accent: .uk)
                // 一键用 Mac 自带词典打开（看完整词条）
                Button {
                    openSystemDictionary(word: entry.word)
                } label: {
                    Image(systemName: "book")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("在 Mac 自带词典中查看完整词条")
            }

            // 各词性释义（每行一个词性）
            let lines = entry.translation
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                let parsed = parseDictLine(line)
                HStack(alignment: .top, spacing: 8) {
                    Text(parsed.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 58, alignment: .leading)
                    Text(parsed.meaning)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// 词典内容转纯文本（用于复制）
    private func dictionaryPlainText(_ entry: LocalDictEntry) -> String {
        var lines: [String] = [entry.word.capitalized]
        if let ph = entry.phonetic, !ph.isEmpty { lines[0] += "  [\(ph)]" }
        for line in entry.translation.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { lines.append(t) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: 底部
    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if let hint = copiedHint {
                Label(hint, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
                    .transition(.opacity)
            } else {
                Text(state.engine)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if state.isWordMode, let entry = state.dictionaryEntry {
                Button {
                    if vocabulary.contains(entry.word) {
                        vocabulary.remove(entry.word)
                        showToast("已从生词本移除")
                    } else {
                        vocabulary.add(word: entry.word, context: state.sourceText)
                        showToast("「\(entry.word)」已加入生词本")
                    }
                } label: {
                    Label(vocabulary.contains(entry.word) ? "已在生词本" : "加入生词本",
                          systemImage: vocabulary.contains(entry.word) ? "checkmark" : "plus")
                }
                .controlSize(.small)
                Button {
                    copy(dictionaryPlainText(entry), hint: "释义已复制")
                } label: {
                    Label("复制释义", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            } else {
                // 朗读原文（用上次选的口音）
                SpeakButton(text: state.sourceText, accent: preferredAccent())
                    .disabled(state.sourceText.isEmpty)
                Button("复制原文") { copy(state.sourceText, hint: "原文已复制") }
                    .controlSize(.small)
                    .disabled(state.isLoading || state.sourceText.isEmpty)
                Button {
                    copy(state.resultText, hint: "译文已复制")
                } label: {
                    Label("复制译文", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(state.isLoading || state.resultText.isEmpty)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private func copy(_ text: String, hint: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copiedHint = hint }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { copiedHint = nil }
        }
    }

    /// 面板内顶部弹出提示（短暂出现后消失）
    private func showToast(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { toast = nil }
        }
    }

    private func startOnlineFallback() {
        debugLog("改用在线翻译")
        onlineTranslate(text: state.sourceText) { text in
            DispatchQueue.main.async {
                if let text = text {
                    state.resultText = text
                    state.engine = "在线翻译"
                }
                state.isLoading = false
            }
        }
    }
}

private struct LanguageBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

// MARK: - 跨版本翻译兼容
// 系统翻译只在 macOS 15 及以上可用；老系统自动走在线翻译

@available(macOS 15.0, *)
struct SystemTranslateModifier: ViewModifier {
    let text: String
    let onResult: (String) -> Void
    let onFailure: () -> Void

    @State private var config: TranslationSession.Configuration?

    func body(content: Content) -> some View {
        content
            .translationTask(config) { session in
                do {
                    debugLog("调用系统翻译")
                    let response = try await session.translate(text)
                    await MainActor.run { onResult(response.targetText) }
                } catch {
                    debugLog("系统翻译失败：\(error)")
                    await MainActor.run { onFailure() }
                }
            }
            .onAppear {
                config = TranslationSession.Configuration(
                    source: Locale.Language(identifier: currentSourceOption().identifier),
                    target: Locale.Language(identifier: currentTargetOption().identifier)
                )
            }
    }
}

extension View {
    @ViewBuilder
    func translateCompat(
        text: String,
        onResult: @escaping (String) -> Void,
        onUnavailable: @escaping () -> Void
    ) -> some View {
        // 单词模式走本地词典，不需要系统翻译
        if text.isEmpty {
            self
        } else if #available(macOS 15.0, *) {
            modifier(SystemTranslateModifier(text: text, onResult: onResult, onFailure: onUnavailable))
        } else {
            onAppear(perform: onUnavailable)
        }
    }
}

// MARK: - 录制快捷键提示面板

struct RecordingView: View {
    @State private var pressed: String?
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard")
                .font(.system(size: 28))
                .foregroundStyle(.tint)
            Text("请按下新的快捷键组合")
                .font(.headline)
            if let pressed = pressed {
                Text(pressed)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tint)
            } else {
                Text("例如：Command + Shift + K")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("要同时按住修饰键 + 字母键；按 Esc 取消")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("取消", action: onCancel)
        }
        .padding(24)
        .frame(width: 360)
    }
}

// MARK: - 浮窗控制器

/// 支持鼠标拖动位置的浮窗
/// 支持拖动位置的浮窗（用系统原生背景拖动，流畅无闪烁）
final class DraggablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 让 NSHostingView 真正透明。
/// 默认 NSHostingView.isOpaque = true，会在其矩形 bounds 内绘制系统背景色，
/// 盖过 SwiftUI 的圆角形状，导致"圆角 + 外围一圈直角"的混合显示。
final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

final class PanelController {
    private var panel: NSPanel?
    private var hostingView: TransparentHostingView<ResultPanelView>?
    private var clickMonitor: Any?
    private var cancellable: AnyCancellable?
    private(set) var state: TranslateState?

    /// 测试模式下不监听外部点击，避免被误关
    var disableClickToClose = false

    private func restoreBackgroundMode() {
        NSApp.setActivationPolicy(.accessory)
    }

    @discardableResult
    func show(text: String, vocabulary: VocabularyStore? = nil) -> TranslateState {
        debugLog("开始显示结果面板")
        close()

        let state = TranslateState()
        state.sourceText = text
        self.state = state

        let root = ResultPanelView(
            state: state,
            vocabulary: vocabulary ?? VocabularyStore(),
            onClose: { [weak self] in self?.close() },
            onRetryOnline: { [weak self] in
                guard let self = self, let state = self.state else { return }
                state.isLoading = true
                state.resultText = ""
                onlineTranslate(text: state.sourceText) { text in
                    DispatchQueue.main.async {
                        if let text = text {
                            state.resultText = text
                            state.engine = "在线翻译"
                        }
                        state.isLoading = false
                    }
                }
            }
        )

        let hosting = TransparentHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        let panel = DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true  // 系统层阴影，不会被 panel frame 裁剪
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovableByWindowBackground = true
        panel.contentView = hosting
        position(panel)

        panel.orderFrontRegardless()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        self.panel = panel
        self.hostingView = hosting

        debugLog("面板已显示，state 已设置")
        cancellable = state.objectWillChange.sink { [weak self] _ in
            // 翻译完成后立刻收回前台身份，避免 Dock 图标长时间停留
            DispatchQueue.main.async {
                if self?.state?.isLoading == false {
                    self?.restoreBackgroundMode()
                }
                // 内容变化后跟着调整面板大小
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.resizeToFit()
                }
            }
        }

        // 首次布局稳定后校准一次尺寸
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.resizeToFit()
        }

        // 单个英文单词 → 词典模式（内置本地词典，查词性 + 多释义）
        if let word = singleEnglishWord(from: text),
           let entry = LocalDictionary.shared.lookup(word) {
            state.isWordMode = true
            state.engine = "本地词典"
            state.dictionaryEntry = entry
            state.isLoading = false
        }

        guard !disableClickToClose else { return state }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self = self, self.panel != nil else { return }
            self.clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                DispatchQueue.main.async { self?.close() }
            }
        }
        return state
    }

    func close() {
        debugLog("面板已关闭")
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        cancellable?.cancel()
        cancellable = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        hostingView = nil
        state = nil
        restoreBackgroundMode()
    }

    /// 根据内容自动调整面板高度，并保证不超出屏幕
    private func resizeToFit() {
        guard let panel = panel, let hosting = hostingView else { return }
        let fitting = hosting.fittingSize
        let targetWidth: CGFloat = min(max(fitting.width, 280), 500)
        let targetHeight: CGFloat = min(max(fitting.height, 100), 520)
        let newSize = NSSize(width: targetWidth, height: targetHeight)
        panel.setContentSize(newSize)

        // 把面板拉回屏幕内
        let screen = NSScreen.screens.first(where: { $0.frame.contains(panel.frame.origin) }) ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        var origin = panel.frame.origin
        if origin.x + newSize.width > vf.maxX { origin.x = vf.maxX - newSize.width }
        if origin.y + newSize.height > vf.maxY { origin.y = vf.maxY - newSize.height }
        if origin.x < vf.minX { origin.x = vf.minX }
        if origin.y < vf.minY { origin.y = vf.minY }
        panel.setFrameOrigin(origin)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = mouse.x + 12
        var y = mouse.y + 12
        if x + 460 > frame.maxX { x = frame.maxX - 460 - 12 }
        if y + 200 > frame.maxY { y = mouse.y - 200 - 12 }
        if y < frame.minY { y = frame.minY + 12 }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - 快捷键

struct HotKeyPreset {
    let title: String
    let keyCode: UInt32
    let modifiers: UInt32
}

let hotKeyPresets: [HotKeyPreset] = [
    HotKeyPreset(title: "Command + S", keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey)),
    HotKeyPreset(title: "Command + Option + S", keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | optionKey)),
    HotKeyPreset(title: "Option + T", keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(optionKey)),
    HotKeyPreset(title: "Command + Option + T", keyCode: UInt32(kVK_ANSI_T), modifiers: UInt32(cmdKey | optionKey)),
    HotKeyPreset(title: "Option + D", keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey)),
    HotKeyPreset(title: "Option + S", keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey))
]

/// 存 -1 表示用自定义快捷键
let customHotKeyFlag = -1
let hotKeyPresetKey = "snaptranslate.hotkey.index"
let hotKeyCustomCodeKey = "snaptranslate.hotkey.customCode"
let hotKeyCustomModsKey = "snaptranslate.hotkey.customMods"

let keyCodeNameMap: [Int: String] = [
    0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H",
    34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P",
    12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X",
    16: "Y", 6: "Z",
    29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
    36: "回车", 48: "Tab", 49: "空格", 51: "删除", 53: "Esc",
    123: "←", 124: "→", 125: "↓", 126: "↑",
    115: "Home", 116: "PageUp", 121: "PageDown",
    96: "F5", 97: "F6", 98: "F7", 99: "F8", 100: "F9", 101: "F10", 103: "F11", 111: "F12"
]

func keyName(for keyCode: UInt32) -> String {
    return keyCodeNameMap[Int(keyCode)] ?? "键\(keyCode)"
}

/// 把按键修饰标记转成系统注册热键用的修饰符
func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
    var m: UInt32 = 0
    if flags.contains(.command) { m |= UInt32(cmdKey) }
    if flags.contains(.shift) { m |= UInt32(shiftKey) }
    if flags.contains(.option) { m |= UInt32(optionKey) }
    if flags.contains(.control) { m |= UInt32(controlKey) }
    return m
}

func modifierNames(for mods: UInt32) -> String {
    var parts: [String] = []
    if mods & UInt32(cmdKey) != 0 { parts.append("Command") }
    if mods & UInt32(shiftKey) != 0 { parts.append("Shift") }
    if mods & UInt32(optionKey) != 0 { parts.append("Option") }
    if mods & UInt32(controlKey) != 0 { parts.append("Control") }
    return parts.joined(separator: " + ")
}

func hotKeyDisplayTitle(keyCode: UInt32, modifiers: UInt32) -> String {
    return modifierNames(for: modifiers) + " + " + keyName(for: keyCode)
}

/// Carbon 修饰符 -> NSMenuItem.keyEquivalentModifierMask
func carbonModifiersToMask(_ mods: UInt32) -> NSEvent.ModifierFlags {
    var f: NSEvent.ModifierFlags = []
    if mods & UInt32(cmdKey) != 0 { f.insert(.command) }
    if mods & UInt32(shiftKey) != 0 { f.insert(.shift) }
    if mods & UInt32(optionKey) != 0 { f.insert(.option) }
    if mods & UInt32(controlKey) != 0 { f.insert(.control) }
    return f
}

/// 碳修饰符 + 按键名 -> "⌘⌥S" 这种符号串
func shortcutSymbol(carbonMods: UInt32, keyName: String) -> String {
    var s = ""
    if carbonMods & UInt32(controlKey) != 0 { s += "⌃" }
    if carbonMods & UInt32(optionKey) != 0 { s += "⌥" }
    if carbonMods & UInt32(shiftKey) != 0 { s += "⇧" }
    if carbonMods & UInt32(cmdKey) != 0 { s += "⌘" }
    s += keyName
    return s
}

// MARK: - 本地英汉词典（内置数据库，完全离线，不联网）

import SQLite3

struct LocalDictEntry {
    let word: String
    let phonetic: String?
    let translation: String   // 中文释义，每行一个词性，如 "n. 光, 光亮"
    let definition: String?   // 英文释义
}

/// 内置英汉词典查询（数据源：开源项目 ECDICT，已精简为 4.4 万常用词）
final class LocalDictionary {
    static let shared = LocalDictionary()
    private var db: OpaquePointer?

    private init() {
        guard let path = Bundle.main.path(forResource: "dict", ofType: "db") else {
            debugLog("未找到内置词典 dict.db")
            return
        }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            debugLog("内置词典已加载")
        } else {
            debugLog("内置词典打开失败")
        }
    }

    private func query(_ word: String) -> LocalDictEntry? {
        guard let db = db else { return nil }
        let sql = "SELECT word, phonetic, translation, definition FROM dict WHERE word = ? COLLATE NOCASE LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (word as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let w = String(cString: sqlite3_column_text(stmt, 0))
        let ph = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) }
        let tr = sqlite3_column_text(stmt, 2).flatMap { String(cString: $0) } ?? ""
        let def = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) }
        return LocalDictEntry(word: w, phonetic: ph, translation: tr, definition: def)
    }

    /// 查词；找不到时自动还原词形变化（复数/过去式/进行时）
    func lookup(_ word: String) -> LocalDictEntry? {
        if let entry = query(word) { return entry }
        let w = word.lowercased()
        var candidates: [String] = []
        if w.hasSuffix("ies"), w.count > 3 { candidates.append(String(w.dropLast(3)) + "y") }
        if w.hasSuffix("ing"), w.count > 4 {
            candidates.append(String(w.dropLast(3)))
            candidates.append(String(w.dropLast(3)) + "e")
        }
        if w.hasSuffix("ed"), w.count > 3 {
            candidates.append(String(w.dropLast(2)))
            candidates.append(String(w.dropLast(1)))
        }
        if w.hasSuffix("es"), w.count > 3 { candidates.append(String(w.dropLast(2))) }
        if w.hasSuffix("s"), w.count > 2 { candidates.append(String(w.dropLast(1))) }
        for c in candidates {
            if let entry = query(c) { return entry }
        }
        return nil
    }
}

/// 把一行释义拆成「词性标签 + 释义」，如 "n. 光, 光亮" -> ("名词", "光, 光亮")
func parseDictLine(_ line: String) -> (label: String, meaning: String) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return ("", "") }

    // 专业领域标签，如 [计] [医]
    if trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") {
        let tag = String(trimmed[...end])
        let rest = String(trimmed[trimmed.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        return (tagName(tag), rest)
    }

    // 普通词性前缀
    let prefixes: [(String, String)] = [
        ("n.", "名词"), ("vt.", "及物动词"), ("vi.", "不及物动词"), ("v.", "动词"),
        ("adj.", "形容词"), ("a.", "形容词"), ("adv.", "副词"), ("prep.", "介词"),
        ("conj.", "连词"), ("pron.", "代词"), ("int.", "感叹词"), ("art.", "冠词"),
        ("num.", "数词"), ("aux.", "助动词")
    ]
    for (prefix, name) in prefixes {
        if trimmed.hasPrefix(prefix) {
            let rest = String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return (name, rest)
        }
    }
    return ("释义", trimmed)
}

/// 领域标签转中文
func tagName(_ tag: String) -> String {
    let map: [String: String] = [
        "[计]": "计算机", "[医]": "医学", "[经]": "经济", "[化]": "化学", "[物]": "物理",
        "[生]": "生物", "[法]": "法律", "[军]": "军事", "[电]": "电子", "[机]": "机械",
        "[建]": "建筑", "[数]": "数学", "[体]": "体育", "[音]": "音乐", "[心]": "心理",
        "[史]": "历史", "[哲]": "哲学", "[宗]": "宗教", "[语]": "语言", "[农]": "农业",
        "[商]": "商业", "[交]": "交通", "[航]": "航空", "[天]": "天文", "[地]": "地理",
        "[印]": "印刷", "[纺]": "纺织", "[冶]": "冶金", "[矿]": "矿业"
    ]
    if let name = map[tag] { return name }
    return tag.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
}

/// 调用 Mac 自带的「词典」App 查这个词。
/// 注意：苹果在新版 macOS 已移除 DictionaryServices 的查询接口（框架导出符号为 0），
/// 无法把系统词典内容嵌进面板，只能用 dict:// 唤起系统词典 App 查看完整内容。
func openSystemDictionary(word: String) {
    if let url = URL(string: "dict://\(word)") {
        NSWorkspace.shared.open(url)
    }
}

/// 从文本中提取「单个英文单词」，不是则返回 nil。
/// 会先剥掉首尾常见标点（OCR 常把 "command." / "light" 这类带符号的结果一起返回），
/// 否则绝大多数真实场景都进不了词典模式。
func singleEnglishWord(from text: String) -> String? {
    guard currentSourceOption().identifier == "en" else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let symbols = CharacterSet(charactersIn: ".,;:!?\"'“”‘’()[]{}<>/\\|-–—*•·、。，；：！？")
    let cleaned = trimmed.trimmingCharacters(in: symbols)
    guard cleaned.count >= 2, cleaned.count <= 30,
          !cleaned.contains(" "), !cleaned.contains("\n"), !cleaned.contains("\t"),
          cleaned.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
    return cleaned
}

// MARK: - 翻译语言

struct LanguageOption {
    let identifier: String      // Locale.Language 标识
    let displayName: String     // 中文显示名
    let myMemoryCode: String    // MyMemory 接口用的语言码
    let visionCode: String      // Vision OCR 用的语言码
    let shortName: String       // 顶部徽章里显示的简短名
}

let languageOptions: [LanguageOption] = [
    LanguageOption(identifier: "en",       displayName: "英语",     myMemoryCode: "en",    visionCode: "en-US",       shortName: "EN"),
    LanguageOption(identifier: "ja",       displayName: "日语",     myMemoryCode: "ja",    visionCode: "ja-JP",       shortName: "JA"),
    LanguageOption(identifier: "ko",       displayName: "韩语",     myMemoryCode: "ko",    visionCode: "ko-KR",       shortName: "KO"),
    LanguageOption(identifier: "fr",       displayName: "法语",     myMemoryCode: "fr",    visionCode: "fr-FR",       shortName: "FR"),
    LanguageOption(identifier: "de",       displayName: "德语",     myMemoryCode: "de",    visionCode: "de-DE",       shortName: "DE"),
    LanguageOption(identifier: "es",       displayName: "西班牙语", myMemoryCode: "es",    visionCode: "es-ES",       shortName: "ES"),
    LanguageOption(identifier: "ru",       displayName: "俄语",     myMemoryCode: "ru",    visionCode: "ru-RU",       shortName: "RU"),
    LanguageOption(identifier: "it",       displayName: "意大利语", myMemoryCode: "it",    visionCode: "it-IT",       shortName: "IT"),
    LanguageOption(identifier: "pt",       displayName: "葡萄牙语", myMemoryCode: "pt",    visionCode: "pt-PT",       shortName: "PT"),
    LanguageOption(identifier: "zh-Hans",  displayName: "中文",     myMemoryCode: "zh-CN", visionCode: "zh-Hans-CN",  shortName: "中文")
]

let sourceLangKey = "snaptranslate.lang.source"
let targetLangKey = "snaptranslate.lang.target"
let defaultSourceID = "en"
let defaultTargetID = "zh-Hans"

func currentSourceOption() -> LanguageOption {
    let id = UserDefaults.standard.string(forKey: sourceLangKey) ?? defaultSourceID
    return languageOptions.first { $0.identifier == id } ?? languageOptions[0]
}

func currentTargetOption() -> LanguageOption {
    let id = UserDefaults.standard.string(forKey: targetLangKey) ?? defaultTargetID
    return languageOptions.first { $0.identifier == id } ?? (languageOptions.last!)
}

// MARK: - 生词本

struct WordEntry: Codable, Identifiable {
    let word: String
    let context: String
    let addedAt: Date
    var id: String { word.lowercased() }
}

/// 生词本：本地 JSON 持久化
final class VocabularyStore: ObservableObject {
    @Published private(set) var words: [WordEntry] = []
    var onChanged: (() -> Void)?

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SnapTranslate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("vocabulary.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([WordEntry].self, from: data) else { return }
        words = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(words) {
            try? data.write(to: fileURL, options: .atomic)
        }
        onChanged?()
    }

    @discardableResult
    func add(word: String, context: String) -> Bool {
        let key = word.lowercased()
        guard !key.isEmpty, !words.contains(where: { $0.id == key }) else { return false }
        words.append(WordEntry(word: word, context: context, addedAt: Date()))
        save()
        return true
    }

    func remove(_ word: String) {
        let key = word.lowercased()
        words.removeAll { $0.id == key }
        save()
    }

    func contains(_ word: String) -> Bool {
        words.contains { $0.id == word.lowercased() }
    }

    func clear() {
        words.removeAll()
        save()
    }
}

/// 从英文句子中提取不重复的单词（只含 a-z，过滤标点/数字/中文）
func extractWords(from text: String) -> [String] {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'-")
    let tokens = text.components(separatedBy: allowed.inverted)
    var seen = Set<String>()
    var result: [String] = []
    for token in tokens {
        let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
        guard trimmed.count >= 2,
              trimmed.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'" || $0 == "-") }),
              !seen.contains(trimmed.lowercased()) else { continue }
        seen.insert(trimmed.lowercased())
        result.append(trimmed)
    }
    return result
}

/// 自动换行布局（macOS 13+）
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// 小喇叭按钮（点一下读一次）
struct SpeakButton: View {
    let text: String
    let accent: SpeechService.Accent
    var onSpoken: ((SpeechService.Accent) -> Void)? = nil

    var body: some View {
        Button {
            SpeechService.shared.speak(text, accent: accent)
            rememberAccent(accent)
            onSpoken?(accent)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 9))
                Text(accent.label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(accent.tip)
    }
}

/// 可点击的单词小标签
struct WordChip: View {
    let word: String
    let added: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                if added {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                }
                Text(word)
                    .font(.system(size: 11, weight: added ? .semibold : .regular))
            }
            .foregroundStyle(added ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(added ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 生词本面板
struct VocabPanelView: View {
    @ObservedObject var store: VocabularyStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("生词本", systemImage: "book.closed")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(store.words.count) 个单词")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("复制全部") { copyAll() }
                    .controlSize(.small)
                    .disabled(store.words.isEmpty)
                Button("清空", role: .destructive) {
                    store.clear()
                }
                .controlSize(.small)
                .disabled(store.words.isEmpty)
            }

            if store.words.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 30))
                        .foregroundStyle(.quaternary)
                    Text("还没有生词\n翻译后点击原文里的单词即可加入")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(store.words) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.word)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(entry.context)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer()
                            Text(entry.addedAt.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button {
                                store.remove(entry.word)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 480, height: 400)
    }

    private func copyAll() {
        let text = store.words.map { $0.word }.joined(separator: ", ")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - 应用委托

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panelController = PanelController()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var recordingPanel: NSPanel?
    private var recordingMonitor: Any?
    private var vocabPanel: NSPanel?
    private let presetKey = hotKeyPresetKey
    let vocabulary = VocabularyStore()

    /// 当前生效的快捷键
    private func currentHotKey() -> (keyCode: UInt32, carbonMods: UInt32, title: String, keyString: String, menuMask: NSEvent.ModifierFlags, shortcutSymbol: String) {
        let index = UserDefaults.standard.integer(forKey: presetKey)
        if index == customHotKeyFlag {
            let code = UInt32(UserDefaults.standard.integer(forKey: hotKeyCustomCodeKey))
            let mods = UInt32(UserDefaults.standard.integer(forKey: hotKeyCustomModsKey))
            if code > 0, mods > 0 {
                let k = keyName(for: code)
                return (code, mods, "自定义：\(hotKeyDisplayTitle(keyCode: code, modifiers: mods))", k.lowercased(), carbonModifiersToMask(mods), shortcutSymbol(carbonMods: mods, keyName: k))
            }
        }
        let safeIndex = min(max(index, 0), hotKeyPresets.count - 1)
        let preset = hotKeyPresets[safeIndex]
        let k = keyName(for: preset.keyCode)
        return (preset.keyCode, preset.modifiers, preset.title, k.lowercased(), carbonModifiersToMask(preset.modifiers), shortcutSymbol(carbonMods: preset.modifiers, keyName: k))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerHotKey()
        vocabulary.onChanged = { [weak self] in self?.rebuildMenu() }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                self?.panelController.close()
            }
            return event
        }
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "截图翻译")
            button.image?.isTemplate = true
        }
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let hotKey = currentHotKey()
        let currentIndex = UserDefaults.standard.integer(forKey: presetKey)
        let source = currentSourceOption()
        let target = currentTargetOption()

        // 菜单主项：用 attributedTitle 显示快捷键（不用 keyEquivalent，
        // 因为 keyEquivalent 会全局注册 Carbon 热键，跟我们自己的 RegisterEventHotKey 冲突）
        let captureItem = NSMenuItem(
            title: "框选屏幕翻译",
            action: #selector(startCapture),
            keyEquivalent: ""
        )
        captureItem.target = self
        let attrTitle = NSMutableAttributedString(
            string: "框选屏幕翻译\t\(hotKey.shortcutSymbol)",
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.labelColor]
        )
        let shortcutRange = NSRange(location: "框选屏幕翻译".count + 1, length: hotKey.shortcutSymbol.count)
        attrTitle.addAttributes([
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.menuFont(ofSize: 0)
        ], range: shortcutRange)
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.tabStops = [NSTextTab(textAlignment: .right, location: 240, options: [:])]
        attrTitle.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: attrTitle.length))
        captureItem.attributedTitle = attrTitle
        menu.addItem(captureItem)

        let clipboardItem = NSMenuItem(
            title: "翻译剪贴板里的截图",
            action: #selector(translateClipboardImage),
            keyEquivalent: ""
        )
        clipboardItem.target = self
        menu.addItem(clipboardItem)

        menu.addItem(NSMenuItem.separator())

        // 翻译语言子菜单
        let sourceSubmenu = NSMenu()
        for (index, lang) in languageOptions.enumerated() {
            let item = NSMenuItem(title: lang.displayName, action: #selector(setSourceLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = lang.identifier == source.identifier ? .on : .off
            sourceSubmenu.addItem(item)
        }
        let sourceItem = NSMenuItem(title: "源语言　（识别）", action: nil, keyEquivalent: "")
        sourceItem.submenu = sourceSubmenu
        menu.addItem(sourceItem)

        let targetSubmenu = NSMenu()
        for (index, lang) in languageOptions.enumerated() {
            let item = NSMenuItem(title: lang.displayName, action: #selector(setTargetLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = lang.identifier == target.identifier ? .on : .off
            targetSubmenu.addItem(item)
        }
        let targetItem = NSMenuItem(title: "目标语言　（翻译为）", action: nil, keyEquivalent: "")
        targetItem.submenu = targetSubmenu
        menu.addItem(targetItem)

        menu.addItem(NSMenuItem.separator())

        let hotkeyMenu = NSMenu()
        for (index, preset) in hotKeyPresets.enumerated() {
            let item = NSMenuItem(title: preset.title, action: #selector(changeHotKey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == currentIndex ? .on : .off
            hotkeyMenu.addItem(item)
        }
        hotkeyMenu.addItem(NSMenuItem.separator())
        let customItem = NSMenuItem(title: "自定义快捷键…", action: #selector(beginCustomHotKey), keyEquivalent: "")
        customItem.target = self
        customItem.state = currentIndex == customHotKeyFlag ? .on : .off
        hotkeyMenu.addItem(customItem)
        let hotkeyItem = NSMenuItem(title: "修改快捷键", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        menu.addItem(NSMenuItem.separator())

        let vocabItem = NSMenuItem(
            title: "生词本（\(vocabulary.words.count)）",
            action: #selector(showVocabPanel),
            keyEquivalent: ""
        )
        vocabItem.target = self
        menu.addItem(vocabItem)

        let checkAssetsItem = NSMenuItem(title: "检查并下载翻译语言包", action: #selector(checkLanguageAssets), keyEquivalent: "")
        checkAssetsItem.target = self
        menu.addItem(checkAssetsItem)

        let permissionItem = NSMenuItem(title: "检查屏幕截图权限", action: #selector(openPermissionSettings), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)

        let quitItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: 切换语言

    @objc private func setSourceLanguage(_ sender: NSMenuItem) {
        let lang = languageOptions[sender.tag]
        UserDefaults.standard.set(lang.identifier, forKey: sourceLangKey)
        rebuildMenu()
    }

    @objc private func setTargetLanguage(_ sender: NSMenuItem) {
        let lang = languageOptions[sender.tag]
        UserDefaults.standard.set(lang.identifier, forKey: targetLangKey)
        rebuildMenu()
    }

    // MARK: 生词本

    @objc private func showVocabPanel() {
        if let panel = vocabPanel, panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "生词本"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        panel.contentView = NSHostingView(rootView: VocabPanelView(store: vocabulary))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        vocabPanel = panel
    }

    /// 检查并下载翻译语言包（macOS 15+ 用系统翻译时才需要）
    @objc private func checkLanguageAssets() {
        if #available(macOS 15.0, *) {
            let source = Locale.Language(identifier: currentSourceOption().identifier)
            let target = Locale.Language(identifier: currentTargetOption().identifier)
            Task { @MainActor in
                let availability = LanguageAvailability()
                let status = await availability.status(from: source, to: target)
                switch status {
                case .installed:
                    showNotice("翻译语言包已安装，可以离线翻译")
                case .supported:
                    let alert = NSAlert()
                    alert.messageText = "需要下载翻译语言包"
                    alert.informativeText = "首次使用「\(currentSourceOption().displayName) → \(currentTargetOption().displayName)」系统翻译时，需要联网下载约几十 MB 的语言包。\n\n点下面的按钮打开系统设置，在「通用 → 语言与地区 → 翻译语言」里打开对应的开关，下载完成后再用一次即可离线翻译。"
                    alert.addButton(withTitle: "打开系统设置")
                    alert.addButton(withTitle: "稍后")
                    if alert.runModal() == .alertFirstButtonReturn {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.languages") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                case .unsupported:
                    showNotice("当前系统翻译暂不支持这个语言对，会自动用在线翻译")
                @unknown default:
                    showNotice("无法判断语言包状态")
                }
            }
        } else {
            showNotice("当前 macOS 版本不需要离线语言包，会自动用在线翻译")
        }
    }

    // MARK: 动作

    func runSelfTest(text: String) {
        debugLog("runSelfTest 启动，text=\(text)")
        panelController.disableClickToClose = true
        let state = panelController.show(text: text, vocabulary: vocabulary)
        debugLog("runSelfTest show() 返回")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            debugLog("runSelfTest 1s 触发：居中")
            for w in NSApp.windows where w is NSPanel { w.center() }
        }
        // 翻译完成后自动把面板视图保存为 PDF（仅用于开发自检）
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            debugLog("=== selftest 5s 触发 ===")
            debugLog("NSApp.windows count: \(NSApp.windows.count)")
            for w in NSApp.windows {
                debugLog("  window: \(type(of: w)) title=\(w.title) isVisible=\(w.isVisible) frame=\(w.frame)")
            }
            for w in NSApp.windows where w is NSPanel {
                w.center()
                if let cv = w.contentView {
                    let bounds = cv.bounds
                    let rep = cv.bitmapImageRepForCachingDisplay(in: bounds)
                    if let rep = rep {
                        rep.size = bounds.size
                        cv.cacheDisplay(in: bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: URL(fileURLWithPath: "/tmp/snaptrans_panel.png"))
                            debugLog("PNG saved size: \(png.count)")
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
            let output = """
            原文：\(state.sourceText)
            译文：\(state.resultText)
            来源：\(state.engine)
            仍在翻译中：\(state.isLoading)
            """
            try? output.write(toFile: "/tmp/snaptrans_selftest.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// 词典模式自检：验证单词（含带标点的）能否正确进入本地词典模式
    func runDictionaryTest(word: String) {
        panelController.disableClickToClose = true
        let state = panelController.show(text: word, vocabulary: vocabulary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            var out = "输入：\(word)\n单词模式：\(state.isWordMode)\n"
            if let entry = state.dictionaryEntry {
                out += "查到：\(entry.word)  音标：\(entry.phonetic ?? "无")\n"
                for line in entry.translation.components(separatedBy: .newlines) {
                    let t = line.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { out += "  \(t)\n" }
                }
            } else {
                out += "未进入词典模式；翻译结果：\(state.resultText)\n"
            }
            try? out.write(toFile: "/tmp/snaptrans_dicttest.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    /// 非交互截取指定区域，用于验证「截图 → 识别 → 翻译 → 显示」整条链路
    func runCaptureTest(rect: String) {
        panelController.disableClickToClose = true
        let path = NSTemporaryDirectory() + "snaptrans-\(UUID().uuidString).png"
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-x", "-R", rect, path]
        task.launch()
        task.waitUntilExit()

        func finish(_ text: String) {
            try? text.write(toFile: "/tmp/snaptrans_capturetest.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        guard FileManager.default.fileExists(atPath: path) else {
            finish("截图失败，可能没有屏幕录制权限")
            return
        }

        let text = extractText(from: path)
        try? FileManager.default.removeItem(atPath: path)

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finish("这块区域没有识别到英文")
            return
        }

        let state = panelController.show(text: text, vocabulary: vocabulary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            finish("原文：\n\(state.sourceText)\n\n译文：\n\(state.resultText)\n来源：\(state.engine)")
        }
    }

    func runOnlineTest(text: String) {
        onlineTranslate(text: text) { result in
            let output = "在线翻译结果：\(result ?? "失败")"
            try? output.write(toFile: "/tmp/snaptrans_onlinetest.txt", atomically: true, encoding: .utf8)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }

    @objc func startCapture() {
        debugLog("startCapture 被调用")
        guard ensureScreenCapturePermission() else { return }
        panelController.close()

        let path = NSTemporaryDirectory() + "snaptrans-\(UUID().uuidString).png"
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-i", "-x", path]
        task.launch()
        task.waitUntilExit()

        guard FileManager.default.fileExists(atPath: path) else { return }

        let text = extractText(from: path)
        try? FileManager.default.removeItem(atPath: path)

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showNotice("这块区域没认出英文，换个位置或放大一点再试试")
        } else {
            panelController.show(text: text, vocabulary: vocabulary)
        }
    }

    /// 确保有录屏权限。没有则引导授权，返回是否有权限。
    @discardableResult
    private func ensureScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }

        // 首次会弹出系统自带的授权窗口，用户点「允许」即授权
        if CGRequestScreenCaptureAccess() {
            let alert = NSAlert()
            alert.messageText = "权限已开启，正在自动重启生效…"
            alert.informativeText = "重启完成后，再按一次快捷键就能直接用了。"
            alert.addButton(withTitle: "好的")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            relaunchApp()
            return false
        }

        // 之前被拒绝过、或系统不再弹窗，改为引导去系统设置手动开启
        showPermissionGuide()
        return false
    }

    @objc private func translateClipboardImage() {
        let pasteboard = NSPasteboard.general
        var data: Data?
        if let png = pasteboard.data(forType: .png) {
            data = png
        } else if let tiff = pasteboard.data(forType: .tiff) {
            data = tiff
        }

        guard let imageData = data else {
            showNotice("剪贴板里没有图片。先按 Command + Shift + 4 截一张图，再点这里")
            return
        }

        let text = extractText(fromImageData: imageData)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showNotice("这张图里没认出英文")
        } else {
            panelController.show(text: text, vocabulary: vocabulary)
        }
    }

    @objc private func changeHotKey(_ sender: NSMenuItem) {
        let index = sender.tag
        UserDefaults.standard.set(index, forKey: presetKey)
        registerHotKey()
        rebuildMenu()
    }

    // MARK: 自定义快捷键

    @objc private func beginCustomHotKey() {
        cancelRecording()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 220),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "自定义快捷键"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        panel.contentView = NSHostingView(rootView: RecordingView(onCancel: { [weak self] in
            self?.cancelRecording()
        }))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recordingPanel = panel

        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRecordingKey(event)
            return nil
        }
    }

    private func handleRecordingKey(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.isEmpty else { return }

        let code = UInt32(event.keyCode)
        let mods = carbonModifiers(from: flags)

        UserDefaults.standard.set(customHotKeyFlag, forKey: presetKey)
        UserDefaults.standard.set(Int(code), forKey: hotKeyCustomCodeKey)
        UserDefaults.standard.set(Int(mods), forKey: hotKeyCustomModsKey)

        cancelRecording()

        if !registerHotKey() {
            UserDefaults.standard.set(0, forKey: presetKey)
            registerHotKey()
            showNotice("这个组合被系统或其他软件占用了，换一个试试")
        }
        rebuildMenu()
    }

    private func cancelRecording() {
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMonitor = nil
        }
        recordingPanel?.orderOut(nil)
        recordingPanel?.close()
        recordingPanel = nil
    }

    // MARK: 权限

    @objc private func openPermissionSettings() {
        if CGPreflightScreenCaptureAccess() {
            let alert = NSAlert()
            alert.messageText = "权限已开启，正在自动重启生效…"
            alert.informativeText = "重启后就能直接使用了。"
            alert.addButton(withTitle: "好的")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            relaunchApp()
            return
        }
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重新启动本工具（权限变更后需要新进程才生效）
    private func relaunchApp() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        try? task.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 提示

    private func showNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showPermissionGuide() {
        if CGPreflightScreenCaptureAccess() {
            showNotice("屏幕录制权限已经开启了，按快捷键就能直接用")
            return
        }

        let alert = NSAlert()
        alert.messageText = "需要在系统设置里开启「屏幕录制」"
        alert.informativeText = "点下面的按钮会打开系统设置，在右侧「屏幕录制」列表里找到「截图翻译」（可能显示为 SnapTranslate），把它的开关打开。\n\n然后回到菜单栏点「检查屏幕截图权限」，工具会自动重启生效。\n\n这是苹果的安全要求，识别过程全部在你自己电脑上完成，不会上传任何内容。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: 全局快捷键

    @discardableResult
    private func registerHotKey() -> Bool {
        unregisterHotKey()

        let hotKey = currentHotKey()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, _, _ -> OSStatus in
                debugLog("★★ 热键被触发 ★★")
                DispatchQueue.main.async { AppDelegate.shared?.startCapture() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        debugLog("InstallEventHandler status=\(installStatus)")

        var hotKeyID = EventHotKeyID(signature: OSType(0x534E4150), id: 1)
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.carbonMods, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        debugLog("注册热键：keyCode=\(hotKey.keyCode) mods=\(hotKey.carbonMods) status=\(status)（0=成功）")
        return status == noErr
    }

    private func unregisterHotKey() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    static weak var shared: AppDelegate?
}

// MARK: - 启动

let delegate = AppDelegate()
AppDelegate.shared = delegate
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--selftest"), index + 1 < arguments.count {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        delegate.runSelfTest(text: arguments[index + 1])
    }
}

if let index = arguments.firstIndex(of: "--speaktest"), index + 1 < arguments.count {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        SpeechService.shared.speak(arguments[index + 1], accent: .us)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            try? "朗读测试已执行".write(toFile: "/tmp/snaptrans_speaktest.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }
}

if let index = arguments.firstIndex(of: "--dicttest"), index + 1 < arguments.count {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        delegate.runDictionaryTest(word: arguments[index + 1])
    }
}

if let index = arguments.firstIndex(of: "--capturetest"), index + 1 < arguments.count {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        delegate.runCaptureTest(rect: arguments[index + 1])
    }
}

if let index = arguments.firstIndex(of: "--onlinetest"), index + 1 < arguments.count {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        delegate.runOnlineTest(text: arguments[index + 1])
    }
}

app.run()
