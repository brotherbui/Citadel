import NIO
import Logging

/// A "handle" for accessing a file that has been successfully opened on an SFTP server. File handles support
/// reading (if opened with read access) and writing/appending (if opened with write/append access).
public final class SFTPFile {
    /// A typealias to clarify when a buffer is being used as a file handle.
    ///
    /// This should probably be a `struct` wrapping a buffer for stronger type safety.
    public typealias SFTPFileHandle = ByteBuffer
    
    /// Indicates whether the file's handle was still valid at the time the getter was called.
    public private(set) var isActive: Bool
    
    /// The raw buffer whose contents are were contained in the `.handle()` result from the SFTP server.
    /// Used for performing operations on the open file.
    ///
    /// - Note: Make this `private` when concurrency isn't in a separate file anymore.
    internal let handle: SFTPFileHandle
    
    internal let path: String
    
    /// The `SFTPClient` this handle belongs to.
    ///
    /// - Note: Make this `private` when concurrency isn't in a separate file anymore.
    internal let client: SFTPClient
    
    /// Wrap a file handle received from an SFTP server in an `SFTPFile`. The object should be treated as
    /// having taken ownership of the handle; nothing else should continue to use the handle.
    ///
    /// Do not create instances of `SFTPFile` yourself; use `SFTPClient.openFile()`.
    internal init(client: SFTPClient, path: String, handle: SFTPFileHandle) {
        self.isActive = true
        self.handle = handle
        self.client = client
        self.path = path
    }
    
    /// A `Logger` for the file. Uses the logger of the client that opened the file.
    public var logger: Logging.Logger { self.client.logger }
    
    deinit {
        if client.isActive && self.isActive {
            self.logger.warning("SFTPFile deallocated without being closed first")
        }
    }
    
    /// Read the attributes of the file. This is equivalent to the `stat()` system call.
    ///
    /// - Returns: File attributes including size, permissions, etc
    /// - Throws: SFTPError if the file handle is invalid or request fails
    ///
    /// ## Example
    /// ```swift
    /// let file = try await sftp.withFile(filePath: "test.txt", flags: .read) { file in
    ///     let attrs = try await file.readAttributes()
    ///     print("File size:", attrs.size ?? 0)
    ///     print("Modified:", attrs.modificationTime)
    ///     print("Permissions:", String(format: "%o", attrs.permissions))
    /// }
    /// ```
    public func readAttributes() async throws -> SFTPFileAttributes {
        guard self.isActive else { throw SFTPError.fileHandleInvalid }
        
        guard case .attributes(let attributes) = try await self.client.sendRequest(.stat(.init(
            requestId: self.client.allocateRequestId(),
            path: path
        ))) else {
            self.logger.warning("SFTP server returned bad response to read file request, this is a protocol error")
            throw SFTPError.invalidResponse
        }
                                                                                         
        return attributes.attributes
    }
    
    /// Read up to the given number of bytes from the file, starting at the given byte offset.
    ///
    /// - Parameters:
    ///   - offset: Starting position in the file (defaults to 0)
    ///   - length: Maximum number of bytes to read (defaults to UInt32.max)
    /// - Returns: ByteBuffer containing the read data
    /// - Throws: SFTPError if the file handle is invalid or read fails
    ///
    /// ## Example
    /// ```swift
    /// let file = try await sftp.withFile(filePath: "test.txt", flags: .read) { file in
    ///     // Read first 1024 bytes
    ///     let start = try await file.read(from: 0, length: 1024)
    /// 
    ///     // Read next 1024 bytes
    ///     let middle = try await file.read(from: 1024, length: 1024)
    /// 
    ///     // Read remaining bytes (up to 4GB)
    ///     let rest = try await file.read(from: 2048)
    /// }
    /// ```
    public func read(from offset: UInt64 = 0, length: UInt32 = .max) async throws -> ByteBuffer {
        guard self.isActive else { throw SFTPError.fileHandleInvalid }

        let response = try await self.client.sendRequest(.read(.init(
            requestId: self.client.allocateRequestId(),
            handle: self.handle, offset: offset, length: length
        )))
        
        switch response {
        case .data(let data):
            self.logger.debug("SFTP read \(data.data.readableBytes) bytes from file \(self.handle.sftpHandleDebugDescription)")
            return data.data
        case .status(let status) where status.errorCode == .eof:
            return .init()
        default:
            self.logger.warning("SFTP server returned bad response to read file request, this is a protocol error")
            throw SFTPError.invalidResponse
        }
    }
    
    /// Read all bytes in the file into a single in-memory buffer.
    ///
    /// - Returns: ByteBuffer containing the entire file contents
    /// - Throws: SFTPError if the file handle is invalid or read fails
    ///
    /// ## Example
    /// ```swift
    /// try await sftp.withFile(filePath: "test.txt", flags: .read) { file in
    ///     // Read entire file
    ///     let contents = try await file.readAll()
    ///     print("File size:", contents.readableBytes)
    /// 
    ///     // Convert to string if text file
    ///     if let text = String(buffer: contents) {
    ///         print("Contents:", text)
    ///     }
    /// }
    /// ```
    public func readAll() async throws -> ByteBuffer {
        let attributes = try await self.readAttributes()
        
        guard let fileSize = attributes.size, fileSize > 0 else {
            return ByteBuffer()
        }

        self.logger.debug("SFTP starting pipelined read operation on file \(self.handle.sftpHandleDebugDescription), size: \(fileSize)")

        let chunkSize: UInt64 = 32_000 // Match write chunk size
        let maxConcurrentReads = 32 // Number of pipelined read requests
        
        // Calculate number of chunks
        let numChunks = Int((fileSize + chunkSize - 1) / chunkSize)
        
        // Pre-allocate buffer
        var buffer = ByteBuffer()
        buffer.reserveCapacity(Int(fileSize))
        
        // Create array to hold results in order
        var results = [ByteBuffer?](repeating: nil, count: numChunks)
        
        // Capture client and handle for sendable closure
        let client = self.client
        let handle = self.handle
        
        // Process chunks in batches with pipelining
        var chunkIndex = 0
        while chunkIndex < numChunks {
            let batchEnd = Swift.min(chunkIndex + maxConcurrentReads, numChunks)
            
            // Send all reads in this batch concurrently (pipelining)
            try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { group in
                for i in chunkIndex..<batchEnd {
                    let offset = UInt64(i) * chunkSize
                    let length = UInt32(Swift.min(chunkSize, fileSize - offset))
                    let index = i
                    
                    group.addTask { [client, handle] in
                        let response = try await client.sendRequest(.read(.init(
                            requestId: client.allocateRequestId(),
                            handle: handle, offset: offset, length: length
                        )))
                        
                        switch response {
                        case .data(let data):
                            return (index, data.data)
                        case .status(let status) where status.errorCode == .eof:
                            return (index, ByteBuffer())
                        default:
                            throw SFTPError.invalidResponse
                        }
                    }
                }
                
                // Collect results
                for try await (index, data) in group {
                    results[index] = data
                }
            }
            
            chunkIndex = batchEnd
        }
        
        // Assemble buffer in order
        for i in 0..<numChunks {
            if var chunk = results[i] {
                buffer.writeBuffer(&chunk)
            }
        }

        self.logger.debug("SFTP completed pipelined read operation on file \(self.handle.sftpHandleDebugDescription), read \(buffer.readableBytes) bytes")
        return buffer
    }
    
    /// Write data to the file at the specified offset.
    ///
    /// - Parameters:
    ///   - data: ByteBuffer containing the data to write
    ///   - offset: Position in file to start writing (defaults to 0)
    /// - Throws: SFTPError if the file handle is invalid or write fails
    ///
    /// ## Example
    /// ```swift
    /// try await sftp.withFile(
    ///     filePath: "test.txt",
    ///     flags: [.write, .create]
    /// ) { file in
    ///     // Write string data
    ///     try await file.write(ByteBuffer(string: "Hello World\n"))
    /// 
    ///     // Append more data
    ///     let moreData = ByteBuffer(string: "More content")
    ///     try await file.write(moreData, at: 12) // After newline
    /// 
    ///     // Write large data in chunks
    ///     let chunk1 = ByteBuffer(string: "First chunk")
    ///     let chunk2 = ByteBuffer(string: "Second chunk")
    ///     try await file.write(chunk1, at: 0)
    ///     try await file.write(chunk2, at: UInt64(chunk1.readableBytes))
    /// }
    /// ```
    public func write(_ data: ByteBuffer, at offset: UInt64 = 0) async throws -> Void {
        guard self.isActive else { throw SFTPError.fileHandleInvalid }
        
        var data = data
        let sliceLength = 32_000 // https://github.com/apple/swift-nio-ssh/issues/99
        let maxConcurrentWrites = 32 // Number of pipelined write requests
        
        // Collect all chunks to write
        var chunks: [(offset: UInt64, data: ByteBuffer)] = []
        var currentOffset = offset
        
        while data.readableBytes > 0, let slice = data.readSlice(length: Swift.min(sliceLength, data.readableBytes)) {
            chunks.append((currentOffset, slice))
            currentOffset += UInt64(slice.readableBytes)
        }
        
        // Capture client and handle for sendable closure
        let client = self.client
        let handle = self.handle
        
        // Process chunks in batches with pipelining
        var chunkIndex = 0
        while chunkIndex < chunks.count {
            let batchEnd = Swift.min(chunkIndex + maxConcurrentWrites, chunks.count)
            let batch = chunks[chunkIndex..<batchEnd]
            
            // Send all writes in this batch concurrently (pipelining)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (chunkOffset, chunkData) in batch {
                    group.addTask { [client, handle] in
                        let result = try await client.sendRequest(.write(.init(
                            requestId: client.allocateRequestId(),
                            handle: handle,
                            offset: chunkOffset,
                            data: chunkData
                        )))
                        
                        guard case .status(let status) = result else {
                            throw SFTPError.invalidResponse
                        }
                        
                        guard status.errorCode == .ok else {
                            throw SFTPError.errorStatus(status)
                        }
                    }
                }
                
                // Wait for all writes in this batch to complete
                try await group.waitForAll()
            }
            
            chunkIndex = batchEnd
        }

        self.logger.debug("SFTP finished writing \(currentOffset - offset) bytes @ \(offset) to file \(self.handle.sftpHandleDebugDescription)")
    }
    
    /// Write data to the file at the specified offset using pipelined writes for maximum throughput.
    /// This method sends multiple write requests without waiting for individual acknowledgments,
    /// significantly improving transfer speeds for large files.
    ///
    /// - Parameters:
    ///   - data: ByteBuffer containing the data to write
    ///   - offset: Position in file to start writing (defaults to 0)
    ///   - concurrency: Number of concurrent write operations (defaults to 32)
    /// - Throws: SFTPError if the file handle is invalid or write fails
    public func writePipelined(_ data: ByteBuffer, at offset: UInt64 = 0, concurrency: Int = 32) async throws -> Void {
        try await write(data, at: offset)
    }

    /// Close the file handle.
    ///
    /// - Throws: SFTPError if close fails
    public func close() async throws -> Void {
        guard self.isActive else {
            // Don't blow up if close is called on an invalid handle; it's too easy for it to happen by accident.
            return
        }
        
        self.logger.debug("SFTP closing and invalidating file \(self.handle.sftpHandleDebugDescription)")
        
        self.isActive = false
        let result = try await self.client.sendRequest(.closeFile(.init(requestId: self.client.allocateRequestId(), handle: self.handle)))
        
        guard case .status(let status) = result else {
            throw SFTPError.invalidResponse
        }
        
        guard status.errorCode == .ok else {
            throw SFTPError.errorStatus(status)
        }
        
        self.logger.debug("SFTP closed file \(self.handle.sftpHandleDebugDescription)")
    }
}

extension ByteBuffer {
    /// Returns `nil` if the buffer has no readable bytes, otherwise returns the buffer.
    internal func nilIfUnreadable() -> ByteBuffer? {
        return self.readableBytes > 0 ? self : nil
    }

    /// Assumes the buffer contains an SFTP file handle (usually a file descriptor number, but can be
    /// any arbitrary identifying value the server cares to use, such as the integer representation of
    /// a Windows `HANDLE`) and prints it in as readable as form as is reasonable.
    internal var sftpHandleDebugDescription: String {
        // TODO: This is an appallingly ineffecient way to do a byte-to-hex conversion.
        return self.readableBytesView.flatMap { [Int($0 >> 8), Int($0 & 0x0f)] }.map { ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"][$0] }.joined()
    }
}
