//
//  FlowConnection.swift
//  Flow
//

import Foundation
import Logging
import Network
import Flower
import Transport

open class FlowConnection: Connection
{
    public var stateUpdateHandler: ((NWConnection.State) -> Void)?
    public var viabilityUpdateHandler: ((Bool) -> Void)?
    
    let log: Logger
    var network: Connection
    
    public init?(flower: FlowerController,
                 host: NWEndpoint.Host,
                 port: NWEndpoint.Port,
                 using parameters: NWParameters,
                 logger: Logger)
    {
        let connectionFactory = NetworkConnectionFactory(host: host, port: port)
        guard let newConnection = connectionFactory.connect(using: .udp)
            else
        {
            return nil
        }
        
        self.network = newConnection
        self.log = logger
    }
    
    public init?(connection: Connection,
                 using parameters: NWParameters,
                 logger: Logger)
    {
        guard let prot = parameters.defaultProtocolStack.internetProtocol, let _ = prot as? NWProtocolUDP.Options
            else
        {
            logger.error("Attempted to initialize protean not as a UDP connection.")
            return nil
        }
        
        self.network = connection
        self.log = logger
    }
    
    public func start(queue: DispatchQueue)
    {
        network.stateUpdateHandler = self.stateUpdateHandler
        network.start(queue: queue)
    }
    
    public func send(content: Data?, contentContext: NWConnection.ContentContext, isComplete: Bool, completion: NWConnection.SendCompletion)
    {
        guard let someData = content
            else
        {
            log.error("Received a send command with no content.")
            switch completion
            {
            case .contentProcessed(let handler):
                handler(nil)
            default:
                return
            }
            
            return
        }
        
//        let proteanTransformer = Protean(config: config)
//        let transformedDatas = proteanTransformer.transform(buffer: someData)
//        guard !transformedDatas.isEmpty, let transformedData = transformedDatas.first
//            else
//        {
//            log.error("Received empty response on call to Protean.Transform")
//
//            switch completion
//            {
//            case .contentProcessed(let handler):
//                handler(nil)
//            default:
//                return
//            }
//
//            return
//        }
        
        let transformedData = someData
        
        network.send(content: transformedData, contentContext: contentContext, isComplete: isComplete, completion: completion)
    }
    
    public func receive(completion: @escaping (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)
    {
        self.receive(minimumIncompleteLength: 1, maximumLength: 1000000, completion: completion)
    }
    
    public func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)
    {
        network.receive(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength)
        { (maybeData, maybeContext, connectionComplete, maybeError) in
            
            //FIXME: Finish protean implementation of read
            guard let _ = maybeData
                else
            {
                self.log.error("Received no content.")
                completion(maybeData, maybeContext, connectionComplete, maybeError)
                return
            }
            
//            let proteanTransformer = Protean(config: self.config)
//            let restored = proteanTransformer.restore(buffer: someData)
//            completion(restored.first, maybeContext, connectionComplete, maybeError)
        }
    }
    
    public func cancel()
    {
        network.cancel()
        
        if let stateUpdate = self.stateUpdateHandler
        {
            stateUpdate(NWConnection.State.cancelled)
        }
        
        if let viabilityUpdate = self.viabilityUpdateHandler
        {
            viabilityUpdate(false)
        }
    }
}
