//
//  LogController.swift — Aevon, Settings side.
//
//  0.2.19 — the operator can read the log on the phone.
//
//  Why this exists: the phone client used for feedback has no "attach local
//  file" action, and the log lives outside the photo library. A page that
//  renders the tail of /var/mobile/Aevon.log is therefore not a convenience —
//  it is the only way a field report can carry evidence without a computer.
//  Two ways out of that page: screenshot it, or tap 复制 and paste the text.
//
//  The page never writes, never clears, never truncates. It reads the last
//  192 KB of a 512 KB file, keeps at most 600 lines, and shows the path and
//  size in the header so a report can prove which file it came from.
//

import UIKit

@objc(AevonLogController)
final class AevonLogController: UIViewController {

    /// Enough for several share attempts, small enough to stay off the
    /// memory radar of the Settings process.
    private let maxBytes: UInt64 = 192 * 1024
    private let maxLines = 600

    private let textView = UITextView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "日志"
        view.backgroundColor = .systemBackground

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.alwaysBounceVertical = true
        textView.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 24, right: 10)
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "复制", style: .plain, target: self, action: #selector(copyAll))
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "刷新", style: .plain, target: self, action: #selector(reloadText))

        reloadText()
        scrollToBottom()
    }

    // MARK: Reading

    @objc private func reloadText() {
        let path = Aevon.logPath
        var info = stat()
        guard stat(path, &info) == 0 else {
            textView.text = "日志还不存在：\n\(path)\n\n"
                + "Aevon 还没写过这个文件，或者日志刚被清空过。"
            return
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            textView.text = "读不到日志：\n\(path)\n\n"
                + "文件存在，但当前进程没有权限打开它。"
            return
        }
        defer { try? handle.close() }

        let size = UInt64(info.st_size)
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()

        var body = String(decoding: data, as: UTF8.self)
        if start > 0, let newline = body.firstIndex(of: "\n") {
            // The window starts mid-line; that fragment is not a record.
            body = String(body[body.index(after: newline)...])
        }
        var lines = body.components(separatedBy: "\n").filter { !$0.isEmpty }
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }

        let header = "文件：\(path)\n"
            + "大小：\(size) B    版本：\(Aevon.version)\n"
            + "显示最近 \(lines.count) 行；完整内容请点右上角「复制」。\n\n"
        textView.text = header + lines.joined(separator: "\n")
    }

    private func scrollToBottom() {
        view.layoutIfNeeded()
        let end = (textView.text as NSString).length
        guard end > 0 else { return }
        textView.scrollRangeToVisible(NSRange(location: end - 1, length: 1))
    }

    // MARK: Actions

    @objc private func copyAll() {
        UIPasteboard.general.string = textView.text
        let sheet = UIAlertController(
            title: "已复制",
            message: "日志已复制到剪贴板，直接粘贴到反馈里即可。",
            preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "好", style: .default, handler: nil))
        present(sheet, animated: true)
    }
}
