//
//  SMTPSocket.swift
//  Hedwig
//
//  Created by Wei Wang on 2016/12/27.
//
//

import Foundation
import TLS
import Socks
import SocksCore
import CLibreSSL

protocol Sock {
    func send(bytes: [UInt8]) throws
    func receive() throws -> [String]
    func connect(servername: String) throws
    func close() throws
    var internalSocket: TCPInternetSocket { get }
}

struct SMTPSocket {
    let sock: Sock
    
    func connect(servername: String) throws -> SMTPResponse {
        try sock.connect(servername: servername)
        let result = try sock.receive()
        
        guard result.count == 1 else {
            throw SMTP.SMTPError.badResponse
        }
        
        return try SMTPResponse(string: result[0])
    }
    
    func send(_ string: String) throws -> SMTPResponse {
        logInTest("C: \(string)")
        try sock.send(bytes: (string + CRLF).toBytes())
        
        var parsed: SMTPResponse? = nil
        var response = try sock.receive()
        var multiple = false
        var result = [String]()
        
        // Workaround for different socket buffer implementation.
        // Some server prefer to buffer one line a time, while some other buffer all lines.
        if response.count == 1 {
            // One line case. Keep getting until can be parsed correctly.
            repeat {
                result.append(response[0])
                do {
                    parsed = try SMTPResponse(string: response[0])
                } catch {
                    multiple = true
                    response = try sock.receive()
                }
            } while parsed == nil
        } else {
            // Multiple lines. Parse until last.
            multiple = true
            response.forEach {
                result.append($0)
                do { parsed = try SMTPResponse(string: $0) }
                catch { }
            }
        }

        let r: SMTPResponse
        
        if multiple {
            r = SMTPResponse(code: parsed!.code, data: result.joined(separator: "\n"))
        } else {
            r = parsed!
        }
        
        logInTest("S: \(r.data)")
        return r
    }
    
    func close() throws {
        try sock.close()
    }
}

extension TLS.Socket: Sock {
    func send(bytes: [UInt8]) throws {
        try send(bytes)
    }
    
    func receive() throws -> [String] {
        let text = try receive(max: 65_535).toString()
        return text.seperated
    }
    
    var internalSocket: TCPInternetSocket {
        return socket
    }
}

extension TLS.Socket {
    /// Convert an existing TCP socket to a TLS socket.
    convenience init(existing socket: TCPInternetSocket,
                     certificates: Certificates,
                     cipher: Config.Cipher,
                     proto: [Config.TLSProtocol],
                     hostName: String) throws
    {
        let context = try Context(mode: .client)
        let config = try Config(context: context, certificates: certificates, cipher: cipher, proto: proto)

        try self.init(config: config, socket: socket)
        tls_connect_socket(config.context.cContext, socket.descriptor, hostName)
        
        currSocket = socket
        currContext = config.context.cContext
    }
}

extension TCPClient: Sock {
    func receive() throws -> [String] {
        let text = try receive(maxBytes: 65_535).toString()
        return text.seperated
    }
    
    func connect(servername: String) throws {
        // Intended empty.
    }
    
    var internalSocket: TCPInternetSocket {
        return socket
    }
}

extension String {
    var seperated: [String] {
        return replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n")
            .filter { $0 != "" }
    }
}