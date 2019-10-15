//
//  SignalRLogger.swift
//  SignalRSwift
//
//  Created by Logan Gauthier on 10/15/19.
//  Copyright © 2019 Jordan Camara. All rights reserved.
//

import Foundation

public protocol SignalRLoggerDelegate: class {
    
    func signalRLog(_ message: String)
}

public class SignalRLogger {
    
    public static weak var delegate: SignalRLoggerDelegate?
    
    static func log(_ message: String) {
        
        delegate?.signalRLog(message)
    }
}
