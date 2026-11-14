// 口令哈希：Argon2id（time=1, memory=64MB, threads=4），PHC 格式，pepper 参与派生。
// 与 Go 版语义一致；新建库无跨语言哈希兼容需求。

import argon2 from "argon2";

const ARGON_OPTS: argon2.Options = {
  type: argon2.argon2id,
  timeCost: 2, // node-argon2 下限为 2（Go 版为 1）；t=2 + 64MB 强度略高于旧版，原生实现延迟可接受
  memoryCost: 64 * 1024, // 64MB（KiB）
  parallelism: 4,
};

export async function hashPassword(password: string, pepper: string): Promise<string> {
  return argon2.hash(password + pepper, ARGON_OPTS);
}

export async function verifyPassword(
  password: string,
  pepper: string,
  phc: string,
): Promise<boolean> {
  try {
    return await argon2.verify(phc, password + pepper);
  } catch {
    // 格式非法等情况按"不匹配"处理（Go 版返回显式错误，此处对外语义一致：false）
    return false;
  }
}
