package auth

import (
	"strings"
	"testing"
)

func TestHashVerifyRoundTrip(t *testing.T) {
	h, err := HashPassword("s3cret-密码!", "pepper-xyz")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(h, "$argon2id$v=19$m=65536,t=1,p=4$") {
		t.Fatalf("PHC 前缀不符: %s", h)
	}
	ok, err := VerifyPassword("s3cret-密码!", "pepper-xyz", h)
	if err != nil || !ok {
		t.Fatalf("正确口令应通过: ok=%v err=%v", ok, err)
	}
	ok, _ = VerifyPassword("wrong", "pepper-xyz", h)
	if ok {
		t.Fatal("错误口令不应通过")
	}
	ok, _ = VerifyPassword("s3cret-密码!", "other-pepper", h)
	if ok {
		t.Fatal("pepper 不同不应通过")
	}
}

func TestHashNonDeterministic(t *testing.T) {
	a, _ := HashPassword("same", "p")
	b, _ := HashPassword("same", "p")
	if a == b {
		t.Fatal("随机盐应产生不同哈希")
	}
}

func TestVerifyMalformed(t *testing.T) {
	for _, bad := range []string{"", "$argon2id$", "$bcrypt$x$y$z$w", "$argon2id$v=abc$m=x,t=1,p=4$AA$AA"} {
		if _, err := VerifyPassword("p", "p", bad); err == nil {
			t.Fatalf("畸形哈希 %q 应报错", bad)
		}
	}
}
