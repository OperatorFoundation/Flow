//
//  Cipher.swift
//  Shadow
//
//  Created by Mafalda on 8/17/20.
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
import CryptoKit

class Cipher
{
    // MARK: Cipher notes from https://github.com/shadowsocks/go-shadowsocks2/blob/master/shadowaead/cipher.go
    
    // AESGCM creates a new Cipher with a pre-shared key. len(psk) must be
    // one of 16, 24, or 32 to select AES-128/196/256-GCM.
    
    // Chacha20Poly1305 creates a new Cipher with a pre-shared key. len(psk)
    // must be 32.
    
    func hkdfSHA1(secret: Data, salt: Data, info: Data) -> Data?
    {
        let outputSize = 32
        
        let iterations = UInt8(ceil(Double(outputSize) / Double(Insecure.SHA1.byteCount)))
        guard iterations <= 255 else {return nil}
        
        let prk = HMAC<Insecure.SHA1>.authenticationCode(for: secret, using: SymmetricKey(data: salt))
        let key = SymmetricKey(data: prk)
        var hkdf = Data()
        var value = Data()
        
        for i in 1...iterations
        {
            value.append(info)
            value.append(i)
            
            let code = HMAC<Insecure.SHA1>.authenticationCode(for: value, using: key)
            hkdf.append(contentsOf: code)
            
            value = Data(code)
        }

        return hkdf.prefix(outputSize)
    }
}

enum CipherMode: Any
{
    case aesGCM
    case chachaPoly
}

