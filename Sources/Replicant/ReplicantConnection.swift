//
//  ReplicantConnection.swift
//  Shapeshifter-Swift-Transports
//
//  Created by Adelita Schule on 11/21/18.
//

import Foundation
import Network

import Transport
import ReplicantSwift

open class ReplicantConnection: Connection
{
    public let aesOverheadSize = 81
    public var stateUpdateHandler: ((NWConnection.State) -> Void)?
    public var viabilityUpdateHandler: ((Bool) -> Void)?
    public var config: ReplicantConfig
    public var replicant: Replicant
    
    var sendTimer: Timer?
    
    var networkQueue = DispatchQueue(label: "Replicant Queue")
    var sendBufferQueue = DispatchQueue(label: "SendBuffer Queue", attributes: .concurrent)
    var decryptedBufferQueue = DispatchQueue(label: "decryptedBuffer Queue", attributes: .concurrent)
    var network: Connection
    var decryptedReceiveBuffer: Data
    var sendBuffer: Data
    
    public convenience init?(host: NWEndpoint.Host,
                 port: NWEndpoint.Port,
                 using parameters: NWParameters,
                 and config: ReplicantConfig)
    {
        let connectionFactory = NetworkConnectionFactory(host: host, port: port)
        guard let newConnection = connectionFactory.connect(using: parameters)
            else
        {
            return nil
        }
        
        self.init(connection: newConnection, using: parameters, and: config)
    }
    
    public init?(connection: Connection,
                using parameters: NWParameters,
                and config: ReplicantConfig)
    {
        guard let prot = parameters.defaultProtocolStack.internetProtocol, let _ = prot as? NWProtocolTCP.Options
            else
        {
            print("Attempted to initialize Replicant not as a TCP connection.")
            return nil
        }
        
        guard let newReplicant = Replicant(withConfig: config)
        else
        {
            print("\nFailed to initialize ReplicantConnection because we failed to initialize Replicant.\n")
            return nil
        }
        
        self.network = connection
        self.config = config
        self.replicant = newReplicant
        self.decryptedReceiveBuffer = Data()
        self.sendBuffer = Data()
        
        introductions
        {
            (maybeIntroError) in
            
            guard maybeIntroError == nil
                else
            {
                print("\nError attempting to meet the server during Replicant Connection Init.\n")
                return
            }
            
            print("\n New Replicant connection is ready. 🎉 \n")
        }
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
            print("Received a send command with no content.")
            switch completion
            {
                case .contentProcessed(let handler):
                    handler(nil)
                default:
                    return
            }
            
            return
        }
        
        let unencryptedChunkSize = self.replicant.config.chunkSize - aesOverheadSize
        
        // Only modify sendBuffer from sendBufferQueue async
        sendBufferQueue.async(flags: .barrier)
        {
            self.sendBuffer.append(someData)
        }
        
        // Only access sendBuffer from sendBufferQueue
        sendBufferQueue.sync
        {
            // Only encrypt and send over network when chunk size is available, leftovers to the buffer
            guard sendBuffer.count >= (unencryptedChunkSize)
                else
            {
                print("Received a send command with content less than chunk size.")
                switch completion
                {
                case .contentProcessed(let handler):
                    handler(nil)
                default:
                    return
                }
                
                return
            }
            
            guard let recipientPublicKey = replicant.polish.recipientPublicKey
            else
            {
                print("\nUnable to send data, no recipient public key.\n")
                
                switch completion
                {
                case .contentProcessed(let handler):
                    handler(nil)
                default:
                    return
                }
                
                return
            }
            
            let dataChunk = sendBuffer[0 ..< unencryptedChunkSize]
            let maybeEncryptedData = replicant.polish.encrypt(payload: dataChunk, usingPublicKey: recipientPublicKey)
            
            // Buffer should only contain unsent data
            sendBuffer = sendBuffer[unencryptedChunkSize...]
            
            // Reset or stop the timer
            if sendBuffer.count > 0
            {
                sendTimer = Timer(timeInterval: TimeInterval(config.chunkTimeout), target: self, selector: #selector(chunkTimeout), userInfo: nil, repeats: true)
            }
            else if sendTimer != nil
            {
                sendTimer!.invalidate()
                sendTimer = nil
            }
            
            network.send(content: maybeEncryptedData, contentContext: contentContext, isComplete: isComplete, completion: completion)
        }
    }
    
    public func receive(completion: @escaping (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)
    {
        self.receive(minimumIncompleteLength: 1, maximumLength: 1000000, completion: completion)
    }
    
    public func receive(minimumIncompleteLength: Int, maximumLength: Int, completion: @escaping (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void)
    {
        // Check to see if we have min length data in decrypted buffer before calling network receive. Skip the call if we do.
        
        //FIXME: Nested threading is not what we want here...
        decryptedBufferQueue.sync
        {
            if decryptedReceiveBuffer.count >= minimumIncompleteLength
            {
                // Make sure that the slice we get isn't bigger than the available data count or the maximum requested.
                let sliceLength = decryptedReceiveBuffer.count < maximumLength ? decryptedReceiveBuffer.count : maximumLength
                
                // Return the requested amount
                let returnData = self.decryptedReceiveBuffer[0 ..< sliceLength]
                
                decryptedBufferQueue.async(flags: .barrier)
                {
                    // Remove what was delivered from the buffer
                    self.decryptedReceiveBuffer = self.decryptedReceiveBuffer[sliceLength...]
                }
                
                completion(returnData, NWConnection.ContentContext.defaultMessage, false, nil)
            }
            else
            {
                network.receive(minimumIncompleteLength: replicant.config.chunkSize, maximumLength: replicant.config.chunkSize)
                { (maybeData, maybeContext, connectionComplete, maybeError) in
                    
                    // Check to see if we got data
                    guard let someData = maybeData
                        else
                    {
                        print("\nReceive called with no content.\n")
                        completion(maybeData, maybeContext, connectionComplete, maybeError)
                        return
                    }
                    
                    let maybeReturnData = self.handleReceivedData(minimumIncompleteLength: minimumIncompleteLength, maximumLength: maximumLength, encryptedData: someData)
                    
                    completion(maybeReturnData, maybeContext, connectionComplete, maybeError)
                }
            }
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
    
    /// This takes an optional data and adds it to the buffer before acting on min/max lengths
    func handleReceivedData(minimumIncompleteLength: Int, maximumLength: Int, encryptedData: Data) -> Data?
    {
        // Try to decrypt the entire contents of the encrypted buffer
        guard let decryptedData = self.replicant.polish.decrypt(payload: encryptedData, usingPrivateKey: self.replicant.polish.privateKey)
        else
        {
            print("Unable to decrypt encrypted receive buffer")
            return nil
        }
        
        // Add decrypted data to the decrypted buffer
        self.decryptedReceiveBuffer.append(decryptedData)
        
        // Check to see if the decrypted buffer meets min/max parameters
        guard decryptedReceiveBuffer.count >= minimumIncompleteLength
            else
        {
            // Not enough data return nothing
            return nil
        }
        
        // Make sure that the slice we get isn't bigger than the available data count or the maximum requested.
        let sliceLength = decryptedReceiveBuffer.count < maximumLength ? decryptedReceiveBuffer.count : maximumLength
        
        // Return the requested amount
        let returnData = self.decryptedReceiveBuffer[0 ..< sliceLength]
        
        // Remove what was delivered from the buffer
        self.decryptedReceiveBuffer = self.decryptedReceiveBuffer[sliceLength...]
        
        return returnData
    }
    
    func voightKampffTest(completion: @escaping (Error?) -> Void)
    {
        // Tone Burst
        self.toneBurstSend
        { (maybeError) in
            
            guard maybeError == nil
            else
            {
                print("ToneBurst failed: \(maybeError!)")
                return
            }
            
            self.handshake
            {
                (maybeHandshakeError) in
                
                completion(maybeHandshakeError)
            }
        }
    }
    
    func toneBurstSend(completion: @escaping (Error?) -> Void)
    {
        guard let toneBurst = replicant.toneBurst
        else
        {
            print("\nOur instance of Replicant does not have a ToneBurst instance.\n")
            return
        }
        
        let sendState = toneBurst.generate()
        
        switch sendState
        {
        case .generating(let nextTone):
            print("\nGenerating tone bursts.\n")
            network.send(content: nextTone, contentContext: .defaultMessage, isComplete: false, completion: NWConnection.SendCompletion.contentProcessed(
            {
                (maybeToneSendError) in
                
                guard maybeToneSendError == nil
                    else
                {
                    print("Received error while sending tone burst: \(maybeToneSendError!)")
                    return
                }
                
                self.toneBurstReceive(finalToneSent: false, completion: completion)
            }))
            
        case .completion:
            print("\nGenerated final toneburst\n")
            toneBurstReceive(finalToneSent: true, completion: completion)
            
        case .failure:
            print("\nFailed to generate requested ToneBurst")
            completion(ToneBurstError.generateFailure)
        }

        
    }
    
    func toneBurstReceive(finalToneSent: Bool, completion: @escaping (Error?) -> Void)
    {
        guard let toneBurst = replicant.toneBurst
            else
        {
            print("\nOur instance of Replicant does not have a ToneBurst instance.\n")
            return
        }
        
        guard let toneLength = self.replicant.toneBurst?.nextRemoveSequenceLength
            else
        {
            // Tone burst is finished
            return
        }
        
        self.network.receive(minimumIncompleteLength: Int(toneLength), maximumLength: Int(toneLength) , completion:
            {
                (maybeToneResponseData, maybeToneResponseContext, connectionComplete, maybeToneResponseError) in
                
                guard maybeToneResponseError == nil
                    else
                {
                    print("\nReceived an error in the server tone response: \(maybeToneResponseError!)\n")
                    return
                }
                
                guard let toneResponseData = maybeToneResponseData
                    else
                {
                    print("\nTone response was empty.\n")
                    return
                }
                
                let receiveState = toneBurst.remove(newData: toneResponseData)
                
                switch receiveState
                {
                case .completion:
                    if !finalToneSent
                    {
                        self.toneBurstSend(completion: completion)
                    }
                    else
                    {
                        completion(nil)
                    }
                    
                case .receiving:
                    self.toneBurstSend(completion: completion)
                    
                case .failure:
                    print("\nTone burst remove failure.\n")
                    completion(ToneBurstError.removeFailure)
                }
        })
    }
    
    func handshake(completion: @escaping (Error?) -> Void)
    {
        // Send public key to server
        guard let serverPublicKey = self.replicant.polish.recipientPublicKey
        else
        {
            print("\nHandshake failed, we do not have the server public key.\n")
            completion(HandshakeError.missingClientKey)
            return
        }
        
        guard let ourPublicKeyData = self.replicant.polish.generateAndEncryptPaddedKeyData(
            fromKey: self.replicant.polish.publicKey,
            withChunkSize: self.replicant.config.chunkSize,
            usingServerKey: serverPublicKey)
            else
        {
            print("\nUnable to generate public key data.\n")
            completion(HandshakeError.publicKeyDataGenerationFailure)
            return
        }
        
        self.network.send(content: ourPublicKeyData, contentContext: .defaultMessage, isComplete: false, completion: NWConnection.SendCompletion.contentProcessed(
        {
            (maybeError) in
                
            guard maybeError == nil
                else
            {
                print("\nReceived error from server when sending our key: \(maybeError!)")
                completion(maybeError!)
                return
            }
            
            let replicantChunkSize = self.replicant.config.chunkSize
            self.network.receive(minimumIncompleteLength: replicantChunkSize, maximumLength: replicantChunkSize, completion:
            {
                (maybeResponse1Data, maybeResponse1Context, _, maybeResponse1Error) in
                
                guard maybeResponse1Error == nil
                    else
                {
                    print("\nReceived an error while waiting for response from server acfter sending key: \(maybeResponse1Error!)\n")
                    completion(maybeResponse1Error!)
                    return
                }
                
                // This data is meaningless it can be discarded
                guard let _ = maybeResponse1Data
                    else
                {
                    print("\nServer key response did not contain data.\n")
                    completion(nil)
                    return
                }
            })
        }))
    }
    
    func introductions(completion: @escaping (Error?) -> Void)
    {
        voightKampffTest
        {
            (maybeVKError) in
            
            // Set the connection state
            guard let stateHandler = self.stateUpdateHandler
                else
            {
                completion(IntroductionsError.nilStateHandler)
                return
            }
            
            guard maybeVKError == nil
                else
            {
                stateHandler(NWConnection.State.cancelled)
                completion(maybeVKError)
                return
            }
            
            self.handshake(completion:
            {
                (maybeHandshakeError) in
                
                guard maybeHandshakeError == nil
                    else
                {
                    stateHandler(NWConnection.State.cancelled)
                    completion(maybeHandshakeError)
                    return
                }
            })
            
            stateHandler(NWConnection.State.ready)
            completion(nil)
        }
    }
    
    @objc func chunkTimeout()
    {
        print("\n⏰  Chunk Timeout Reached\n  ⏰")
    }
    
}

enum ToneBurstError: Error
{
    case generateFailure
    case removeFailure
}

enum HandshakeError: Error
{
    case publicKeyDataGenerationFailure
    case noClientKeyData
    case invalidClientKeyData
    case missingClientKey
    case clientKeyDataIncorrectSize
    case unableToDecryptData
}

enum IntroductionsError: Error
{
    case nilStateHandler
}
