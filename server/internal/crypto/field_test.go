package crypto

import (
	"bytes"
	"crypto/rand"
	"testing"
)

func testKey(t *testing.T) []byte {
	t.Helper()
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		t.Fatal(err)
	}
	return k
}

func TestSealOpenRoundTrip(t *testing.T) {
	key := testKey(t)
	for _, pt := range []string{"", "hello", "-----BEGIN OPENSSH PRIVATE KEY-----", "中文密文🔐"} {
		sealed, err := Seal(key, []byte(pt))
		if err != nil {
			t.Fatalf("Seal(%q): %v", pt, err)
		}
		if sealed == pt {
			t.Fatal("密文不应等于明文")
		}
		got, err := Open(key, sealed)
		if err != nil {
			t.Fatalf("Open: %v", err)
		}
		if !bytes.Equal(got, []byte(pt)) {
			t.Fatalf("往返不一致: want %q got %q", pt, got)
		}
	}
}

func TestOpenWrongKey(t *testing.T) {
	sealed, err := Seal(testKey(t), []byte("secret"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Open(testKey(t), sealed); err == nil {
		t.Fatal("错误密钥应当解密失败")
	}
}

func TestOpenTampered(t *testing.T) {
	key := testKey(t)
	sealed, _ := Seal(key, []byte("secret"))
	b := []byte(sealed)
	b[len(b)-3] ^= 0xFF // 破坏 tag 区域
	if _, err := Open(key, string(b)); err == nil {
		t.Fatal("篡改后应解密失败")
	}
}

func TestSealNonDeterministic(t *testing.T) {
	key := testKey(t)
	a, _ := Seal(key, []byte("same"))
	b, _ := Seal(key, []byte("same"))
	if a == b {
		t.Fatal("随机 nonce 应使同一明文产生不同密文")
	}
}

func TestOpenUnknownVersion(t *testing.T) {
	if _, err := Open(testKey(t), "v9:AAAA"); err == nil {
		t.Fatal("未知版本应报错")
	}
}
