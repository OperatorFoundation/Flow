//
//  FlowConnectionFactory.swift
//  Flow
//
//  Created by Dr. Brandon Wiley on 11/1/18.
//  MIT License
//
//  Copyright (c) 2020 Operator Foundation
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation
import Logging

import Flower
import Transport
import Net

open class FlowConnectionFactory: ConnectionFactory
{
    public var name: String = "Flow"
    
    let flower: FlowerController
    let host: NWEndpoint.Host
    let port: NWEndpoint.Port
    let log: Logger
    
    init(flower: FlowerController, host: NWEndpoint.Host, port: NWEndpoint.Port, logger: Logger)
    {
        self.flower = flower
        self.host = host
        self.port = port
        self.log = logger
    }
    
    public func connect(using parameters: NWParameters) -> Connection?
    {
        return FlowConnection(flower: flower, host: host, port: port, using: parameters, logger: log)
    }
}
