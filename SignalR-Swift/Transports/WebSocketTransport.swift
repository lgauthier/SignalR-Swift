//
//  WebSocketTransport.swift
//  SignalR-Swift
//
//  
//  Copyright © 2017 Jordan Camara. All rights reserved.
//

import Foundation
import Starscream
import Alamofire

private typealias WebSocketStartClosure = (String?, Error?) -> ()

public class WebSocketTransport: HttpTransport, WebSocketDelegate {
    
    var reconnectDelay = 2.0
    private var connectionInfo: WebSocketConnectionInfo?
    private var webSocket: WebSocket?
    private var startClosure: WebSocketStartClosure?
    private var connectTimeoutOperation: BlockOperation?

    override public var name: String? {
        return "webSockets"
    }

    override public var supportsKeepAlive: Bool {
        return true
    }

    override public func negotiate(connection: ConnectionProtocol, connectionData: String?, completionHandler: ((NegotiationResponse?, Error?) -> ())?) {
        super.negotiate(connection: connection, connectionData: connectionData, completionHandler: completionHandler)
    }

    override public func start(connection: ConnectionProtocol, connectionData: String?, completionHandler: ((Any?, Error?) -> ())?) {
        self.connectionInfo = WebSocketConnectionInfo(connection: connection, data: connectionData)

        // perform connection
        self.performConnect(completionHandler: completionHandler)
    }

    override public func send(connection: ConnectionProtocol, data: Any, connectionData: String?, completionHandler: ((Any?, Error?) -> ())?) {
        if let dataString = data as? String {
            self.webSocket?.write(string: dataString)
        } else if let dataDict = data as? [String: Any] {
            self.webSocket?.write(string: dataDict.toJSONString()!)
        }
        
        completionHandler?(nil, nil)
    }

    override public func abort(connection: ConnectionProtocol, timeout: Double, connectionData: String?) {
        self.stopWebSocket()
        super.abort(connection: connection, timeout: timeout, connectionData: connectionData)
    }

    override public func lostConnection(connection: ConnectionProtocol) {
        self.stopWebSocket()

        if self.tryCompleteAbort() {
            return
        }

        self.reconnect(connection: self.connectionInfo?.connection)
    }

    private func stopWebSocket() {
        self.webSocket?.delegate = nil
        self.webSocket?.disconnect()
        self.webSocket = nil
    }

    // MARK: - WebSockets transport

    func performConnect(completionHandler: ((_ response: String?, _ error: Error?) -> ())?) {
        self.performConnect(reconnecting: false, completionHandler: completionHandler)
    }

    func performConnect(reconnecting: Bool, completionHandler: ((_ response: String?, _ error: Error?) -> ())?) {
        let connection = self.connectionInfo?.connection
        var parameters: [String: Any] = [
            "transport": self.name!,
            "connectionToken": connection?.connectionToken ?? "",
            "messageId": connection?.messageId ?? "",
            "groupsToken": connection?.groupsToken ?? "",
            "connectionData": self.connectionInfo?.data ?? ""
        ]

        if let queryString = self.connectionInfo?.connection?.queryString {
            for (key, value) in queryString {
                parameters[key] = value
            }
        }

        var urlComponents = URLComponents(string: connection!.url)
        if let urlScheme = urlComponents?.scheme {
            if urlScheme.hasPrefix("https") {
                urlComponents?.scheme = "wss"
            } else if urlScheme.hasPrefix("http") {
                urlComponents?.scheme = "ws"
            }
        }

        do {
            let baseUrl = try urlComponents?.asURL()

            let url = reconnecting ? baseUrl!.absoluteString.appending("reconnect") : baseUrl!.absoluteString.appending("connect")

            let request = connection?.getRequest(url: url, httpMethod: .get, encoding: URLEncoding.default, parameters: parameters, timeout: 30)

            self.startClosure = completionHandler
            if let startClosure = self.startClosure {
                self.connectTimeoutOperation = BlockOperation(block: { [weak self] in
                    guard let strongSelf = self else { return }

                    let userInfo = [
                        NSLocalizedDescriptionKey: NSLocalizedString("Connection timed out.", comment: "timeout error description"),
                        NSLocalizedFailureReasonErrorKey: NSLocalizedString("Connection did not receive initialized message before the timeout.", comment: "timeout error reason"),
                        NSLocalizedRecoverySuggestionErrorKey: NSLocalizedString("Retry or switch transports.", comment: "timeout error retry suggestion")
                    ]
                    let error = NSError(domain: "com.autosoftdms.SignalR-Swift.\(type(of: strongSelf))", code: NSURLErrorTimedOut, userInfo: userInfo)
                    strongSelf.stopWebSocket()

                    strongSelf.startClosure = nil
                    startClosure(nil, error)
                })

                self.connectTimeoutOperation?.perform(#selector(BlockOperation.start), with: nil, afterDelay: connection!.transportConnectTimeout)
            }

            if let encodedRequest = request?.request {
                self.webSocket = WebSocket(request: encodedRequest, certPinner: FoundationSecurity(allowSelfSigned: connection?.webSocketAllowsSelfSignedSSL ?? false))
                self.webSocket!.delegate = self
                self.webSocket!.connect()
            }
        } catch {

        }
    }

    func reconnect(connection: ConnectionProtocol?) {
        _ = BlockOperation { [weak self] in
            if let strongSelf = self, let connection = connection, Connection.ensureReconnecting(connection: connection) {
                strongSelf.performConnect(reconnecting: true, completionHandler: nil)
            }
            }.perform(#selector(BlockOperation.start), with: nil, afterDelay: self.reconnectDelay)
    }

    // MARK: - WebSocketDelegate
    
    public func didReceive(event: WebSocketEvent, client: WebSocket) {
        
        switch event {
        case .connected:
            handleDidConnect(client: client)
        
        case .disconnected(let reason, let code):
            SignalRLogger.log("Did receive \"disconnected\" event (reason: \(reason), code: \(code)).")
            handleDidDisconnect(client: client, reason: reason, code: code)
        
        case .text(let string):
            handleDidReceiveMessage(client: client, text: string)
        
        case .binary(let data):
            SignalRLogger.log("Did receive \"binary\" event (data: \(String(data: data, encoding: .utf8) ?? "nil")).")
        
        case .pong(let data):
            SignalRLogger.log("Did receive \"pong\" event (data: \(data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil")).")
        
        case .ping(let data):
            SignalRLogger.log("Did receive \"ping\" event (data: \(data.flatMap { String(data: $0, encoding: .utf8) } ?? "nil")).")
        
        case .error(let error):
            SignalRLogger.log("Did receive \"error\" event (error: \(error?.localizedDescription ?? "nil")).")
            handleError(error)
            
        case .viablityChanged(let isViable):
            SignalRLogger.log("Did receive \"viabilityChanged\" event (isViable: \(isViable)).")
            
        case .reconnectSuggested(let isReconnectSuggested):
            SignalRLogger.log("Did receive \"reconnectSuggested\" event (isReconnectSuggested: \(isReconnectSuggested)).")
            
        case .cancelled:
            SignalRLogger.log("Did receive \"cancelled\" event.")
        }
    }
    
    private func handleDidConnect(client: WebSocket) {
        
        if let connection = self.connectionInfo?.connection, connection.changeState(oldState: .reconnecting, toState: .connected) {
            connection.didReconnect()
        }
    }
    
    private func handleDidDisconnect(client: WebSocket, reason: String, code: UInt16) {
        
        if !self.tryCompleteAbort() {
            self.reconnect(connection: self.connectionInfo?.connection)
        }
    }
    
    private func handleError(_ error: Error?) {
        
        if let startClosure = self.startClosure, let connectTimeoutOperation = self.connectTimeoutOperation {
            NSObject.cancelPreviousPerformRequests(withTarget: connectTimeoutOperation, selector: #selector(BlockOperation.start), object: nil)

            self.connectTimeoutOperation = nil
            self.stopWebSocket()

            self.startClosure = nil
            startClosure(nil, error)
        } else if !self.startedAbort {
            self.reconnect(connection: self.connectionInfo?.connection)
        }
    }

    private func handleDidReceiveMessage(client: WebSocket, text: String) {
        
        var timedOut = false
        var disconnected = false

        if let connection = self.connectionInfo?.connection, let data = text.data(using: .utf8) {
            connection.processResponse(response: data, shouldReconnect: &timedOut, disconnected: &disconnected)
        }

        if let startClosure = self.startClosure, let connectTimeoutOperation = self.connectTimeoutOperation {
            NSObject.cancelPreviousPerformRequests(withTarget: connectTimeoutOperation, selector: #selector(BlockOperation.start), object: nil)
            self.connectTimeoutOperation = nil

            self.startClosure = nil
            startClosure(nil, nil)
        }

        if disconnected {
            self.connectionInfo?.connection?.disconnect()
            self.stopWebSocket()
        }
    }
}
