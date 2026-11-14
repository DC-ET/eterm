// 登录与设备 token（与 Go 版语义一致）。

import { createHash, randomBytes } from "node:crypto";
import type { Db } from "../store/db.ts";
import * as userstore from "../store/userstore.ts";

export const MAX_FAILED_LOGINS = 5;
export const LOCK_DURATION_SECS = 15 * 60;

export class BadCredentialsError {}
export class DeviceNameError {}
export class NoVaultError {}
export class LockedError {
  constructor(readonly until: Date) {}
}

export interface LoginResult {
  token: string;
  deviceId: string;
  userId: string;
  username: string;
  vaultId: string;
}

export class AuthService {
  constructor(
    private readonly db: Db,
    private readonly pepper: string,
  ) {}

  /** 校验口令、处理失败锁定、注册/复用设备并签发 token。 */
  async login(
    username: string,
    password: string,
    deviceName: string,
    platform: string,
    ip: string | null,
  ): Promise<LoginResult> {
    if (!deviceName || !platform) throw new DeviceNameError();
    const { verifyPassword } = await import("./argon.ts");
    const u = await userstore.getUserByUsername(this.db, username);
    if (!u) throw new BadCredentialsError(); // 不区分用户不存在，防枚举
    if (u.lockedUntil && u.lockedUntil.getTime() > Date.now()) {
      throw new LockedError(u.lockedUntil);
    }
    if (!(await verifyPassword(password, this.pepper, u.pwdHash))) {
      await userstore.audit(this.db, u.id, null, "auth.login.fail", "", null, null, ip);
      const { locked, until } = await userstore.registerLoginFailure(
        this.db,
        u.id,
        MAX_FAILED_LOGINS,
        LOCK_DURATION_SECS,
      );
      if (locked) {
        await userstore.audit(this.db, u.id, null, "auth.lockout", "", null, null, ip);
        throw new LockedError(until ?? new Date());
      }
      throw new BadCredentialsError();
    }
    await userstore.resetLoginFailure(this.db, u.id);

    const token = randomBytes(32).toString("base64url");
    const tokenHash = sha256(token);
    const deviceId = await userstore.upsertDevice(this.db, u.id, deviceName, platform, tokenHash);
    let vaultId: string;
    try {
      vaultId = await userstore.firstVaultOfUser(this.db, u.id);
    } catch {
      throw new NoVaultError();
    }
    await userstore.audit(
      this.db,
      u.id,
      deviceId,
      "auth.login.ok",
      "device",
      deviceId,
      { device_name: deviceName, platform },
      ip,
    );
    return { token, deviceId, userId: u.id, username: u.username, vaultId };
  }
}

export function sha256(s: string): Buffer {
  return createHash("sha256").update(s).digest();
}
