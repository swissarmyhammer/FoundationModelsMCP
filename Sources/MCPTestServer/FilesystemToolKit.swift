import MCP

/// A minimal in-memory file store backing ``ScriptedServer``'s
/// filesystem-style multi-tool mode (scenario 2).
///
/// Deliberately not the real filesystem: scripted scenarios need
/// deterministic, disposable state per test, not sandboxing or real I/O.
public actor VirtualFilesystem {
    private var files: [String: String]

    /// Creates a virtual filesystem seeded with `initialFiles`.
    ///
    /// - Parameter initialFiles: The starting path-to-content map. Defaults
    ///   to empty.
    public init(initialFiles: [String: String] = [:]) {
        self.files = initialFiles
    }

    /// Every path currently stored, sorted for deterministic listing.
    ///
    /// - Returns: All paths currently stored, sorted for deterministic
    ///   listing.
    public func listPaths() -> [String] {
        files.keys.sorted()
    }

    /// Reads one file's content.
    ///
    /// - Parameter path: The path to read.
    /// - Returns: The file's content, or `nil` if `path` doesn't exist.
    public func read(path: String) -> String? {
        files[path]
    }

    /// Writes (creating or overwriting) one file's content.
    ///
    /// - Parameters:
    ///   - path: The path to write.
    ///   - content: The new content.
    public func write(path: String, content: String) {
        files[path] = content
    }
}

extension ScriptedServer {
    /// Registers a "filesystem-style" multi-tool mode over a fresh
    /// ``VirtualFilesystem``: `list_files`, `read_file`, and `write_file` —
    /// scenario 2.
    ///
    /// - Parameter initialFiles: The starting path-to-content map for the
    ///   backing ``VirtualFilesystem``. Defaults to empty.
    /// - Returns: The backing ``VirtualFilesystem``, so a test can seed or
    ///   inspect it directly alongside driving it through `tools/call`.
    @discardableResult
    public func addFilesystemTools(initialFiles: [String: String] = [:]) -> VirtualFilesystem {
        let filesystem = VirtualFilesystem(initialFiles: initialFiles)
        addListFilesTool(filesystem: filesystem)
        addReadFileTool(filesystem: filesystem)
        addWriteFileTool(filesystem: filesystem)
        return filesystem
    }

    /// Registers `list_files`, listing every path currently stored in
    /// `filesystem`.
    ///
    /// - Parameter filesystem: The backing virtual filesystem.
    private func addListFilesTool(filesystem: VirtualFilesystem) {
        addScriptedTool(
            name: "list_files",
            description: "Lists every path in the virtual filesystem.",
            inputSchema: JSONSchemaBuilder.emptySchema
        ) { _ in
            let paths = await filesystem.listPaths()
            return CallTool.Result(
                content: [
                    .text(text: paths.joined(separator: "\n"), annotations: nil, _meta: nil)
                ]
            )
        }
    }

    /// Registers `read_file`, reading one file's content from `filesystem`.
    ///
    /// - Parameter filesystem: The backing virtual filesystem.
    private func addReadFileTool(filesystem: VirtualFilesystem) {
        addScriptedTool(
            name: "read_file",
            description: "Reads one file's content from the virtual filesystem.",
            inputSchema: JSONSchemaBuilder.object(
                properties: ["path": JSONSchemaBuilder.string()], required: ["path"])
        ) { params in
            guard let path = params.arguments?["path"]?.stringValue else {
                throw MCPError.invalidParams("read_file requires a \"path\" argument")
            }
            guard let content = await filesystem.read(path: path) else {
                return CallTool.Result(
                    content: [
                        .text(text: "No such file: \(path)", annotations: nil, _meta: nil)
                    ],
                    isError: true
                )
            }
            return CallTool.Result(
                content: [.text(text: content, annotations: nil, _meta: nil)])
        }
    }

    /// Registers `write_file`, writing (creating or overwriting) one file in
    /// `filesystem`.
    ///
    /// - Parameter filesystem: The backing virtual filesystem.
    private func addWriteFileTool(filesystem: VirtualFilesystem) {
        addScriptedTool(
            name: "write_file",
            description: "Writes (creating or overwriting) one file in the virtual filesystem.",
            inputSchema: JSONSchemaBuilder.object(
                properties: [
                    "path": JSONSchemaBuilder.string(),
                    "content": JSONSchemaBuilder.string(),
                ],
                required: ["path", "content"]
            )
        ) { params in
            guard let path = params.arguments?["path"]?.stringValue,
                let content = params.arguments?["content"]?.stringValue
            else {
                throw MCPError.invalidParams(
                    "write_file requires \"path\" and \"content\" arguments")
            }
            await filesystem.write(path: path, content: content)
            return CallTool.Result(
                content: [.text(text: "wrote \(path)", annotations: nil, _meta: nil)])
        }
    }
}
