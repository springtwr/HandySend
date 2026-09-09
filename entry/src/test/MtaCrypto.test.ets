import { describe, it, expect } from '@ohos/hypium'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'
import { MtaCrypto } from '../main/ets/service/mta/MtaCrypto'
import { MtaConstants } from '../main/ets/service/mta/MtaConstants'
import { P2pInfoJson } from '../main/ets/model/mta/MtaReceiveModels'

/** 用共享密钥以 AES-256-CTR 加密单个字段并 Base64 编码（仅测试侧构造密文用） */
function aesCtrEncrypt(sharedKey: Uint8Array, plaintext: string): string {
  let keyBlob: cryptoFramework.DataBlob = { data: sharedKey }
  let symGenerator = cryptoFramework.createSymKeyGenerator(MtaConstants.AES_SYM_ALGORITHM)
  let symKey = symGenerator.convertKeySync(keyBlob)
  let ivBlob: cryptoFramework.DataBlob = { data: MtaConstants.aesIvBytes() }
  let params: cryptoFramework.IvParamsSpec = { iv: ivBlob, algName: 'IvParamsSpec' }
  let cipher = cryptoFramework.createCipher(MtaConstants.AES_ALGORITHM)
  cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, params)
  let data = new util.TextEncoder().encodeInto(plaintext)
  let out = cipher.doFinalSync({ data: data })
  return new util.Base64Helper().encodeToStringSync(out.data, util.Type.BASIC)
}

/** 逐字节比较两个数组 */
function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) {
    return false
  }
  for (let i = 0; i < left.length; i++) {
    if (left[i] !== right[i]) {
      return false
    }
  }
  return true
}

// MtaCrypto 的 ECDH 协商与 AES-256-CTR 加解密往返测试（依赖系统加解密能力）。
export default function MtaCryptoTest() {
  describe('MtaCryptoTest', () => {
    it('shared_key_length_and_symmetry', 0, async (done: Function) => {
      let alice = new MtaCrypto()
      let bob = new MtaCrypto()
      let alicePub = await alice.generateKeyPair()
      let bobPub = await bob.generateKeyPair()
      expect(alicePub.length > 0).assertTrue()
      expect(bobPub.length > 0).assertTrue()

      let keyA = await alice.deriveSharedKey(bobPub)
      let keyB = await bob.deriveSharedKey(alicePub)
      expect(keyA.length).assertEqual(MtaConstants.SHARED_KEY_LENGTH)
      expect(keyB.length).assertEqual(MtaConstants.SHARED_KEY_LENGTH)
      expect(bytesEqual(keyA, keyB)).assertTrue()
      done()
    })

    it('decrypt_credentials_roundtrip', 0, async (done: Function) => {
      // 发送方 bob 加密凭据，接收方 alice 解密
      let alice = new MtaCrypto()
      let bob = new MtaCrypto()
      let alicePub = await alice.generateKeyPair()
      let bobPub = await bob.generateKeyPair()
      let bobKey = await bob.deriveSharedKey(alicePub)

      let info = new P2pInfoJson()
      info.key = bobPub
      info.ssid = aesCtrEncrypt(bobKey, 'DIRECT-abcd1234')
      info.psk = aesCtrEncrypt(bobKey, 'pass1234')
      info.mac = aesCtrEncrypt(bobKey, 'aa:bb:cc:dd:ee:ff')

      let credentials = await alice.decryptCredentials(info)
      expect(credentials.ssid).assertEqual('DIRECT-abcd1234')
      expect(credentials.psk).assertEqual('pass1234')
      expect(credentials.mac).assertEqual('aa:bb:cc:dd:ee:ff')
      done()
    })

    it('missing_key_falls_back_to_plaintext', 0, async (done: Function) => {
      let alice = new MtaCrypto()
      await alice.generateKeyPair()
      let info = new P2pInfoJson()
      info.key = ''
      info.ssid = 'DIRECT-plain'
      info.psk = 'plainpass'
      info.mac = '11:22:33:44:55:66'

      let credentials = await alice.decryptCredentials(info)
      expect(credentials.ssid).assertEqual('DIRECT-plain')
      expect(credentials.psk).assertEqual('plainpass')
      expect(credentials.mac).assertEqual('11:22:33:44:55:66')
      done()
    })

    it('derive_without_local_keypair_rejects', 0, async (done: Function) => {
      let alice = new MtaCrypto()
      let bob = new MtaCrypto()
      let bobPub = await bob.generateKeyPair()
      let threw: boolean = false
      try {
        await alice.deriveSharedKey(bobPub)
      } catch (_e) {
        threw = true
      }
      expect(threw).assertTrue()
      done()
    })

    it('reset_clears_keypair', 0, async (done: Function) => {
      let alice = new MtaCrypto()
      await alice.generateKeyPair()
      expect(alice.hasKeyPair()).assertTrue()
      alice.reset()
      expect(alice.hasKeyPair()).assertFalse()
      expect(alice.getPublicKeyBase64()).assertEqual('')
      done()
    })
  })
}
