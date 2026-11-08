/**
 * 集群证书工具（需求 10.4 / 交付物 D7）
 *
 *   npm run certs -- init-ca --out ./certs
 *   npm run certs -- issue   --ca ./certs --name node-1 --hosts 10.0.0.1,node-1.internal
 *   npm run certs -- verify  --ca ./certs --cert ./certs/node-1.crt.pem
 *   npm run certs -- show    --cert ./certs/node-1.crt.pem
 *
 * 实现说明：证书由 openssl 命令行生成，而不是纯 JS 库。
 * 原因：JS 库签出的证书在 issuer DN 的字符串编码上与 CA 主体不一致，
 * OpenSSL / Node 的 TLS 校验会报 "unable to get local issuer certificate"。
 * openssl 产出的是标准证书，能被所有主流 TLS 实现正确验证。
 */
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';

function fail(message: string): never {
  console.error(`✗ ${message}`);
  process.exit(1);
}

function parseArgs(argv: string[]): { command: string; flags: Record<string, string> } {
  const [command, ...rest] = argv;
  const flags: Record<string, string> = {};
  for (let i = 0; i < rest.length; i += 1) {
    const token = rest[i]!;
    if (token.startsWith('--')) {
      const key = token.slice(2);
      const value = rest[i + 1] && !rest[i + 1]!.startsWith('--') ? rest[++i]! : 'true';
      flags[key] = value;
    }
  }
  return { command: command ?? '', flags };
}

/** 找到可用的 openssl */
function findOpenssl(): string {
  const candidates = [
    process.env.OPENSSL_BIN,
    'C:\\Program Files\\Git\\usr\\bin\\openssl.exe',
    'C:\\Program Files\\OpenSSL-Win64\\bin\\openssl.exe',
    '/usr/bin/openssl',
    'openssl',
  ].filter(Boolean) as string[];

  for (const candidate of candidates) {
    if (candidate === 'openssl' || existsSync(candidate)) {
      const probe = spawnSync(candidate, ['version'], { encoding: 'utf8' });
      if (probe.status === 0) return candidate;
    }
  }
  fail('找不到 openssl。请安装 Git for Windows（自带 openssl），或设置环境变量 OPENSSL_BIN');
}

function run(openssl: string, args: string[]): string {
  const result = spawnSync(openssl, args, { encoding: 'utf8' });
  if (result.status !== 0) {
    console.error(result.stderr?.trim() ?? '');
    fail(`openssl 执行失败：${args.join(' ')}`);
  }
  return result.stdout;
}

function ensureDir(dir: string): void {
  mkdirSync(dir, { recursive: true });
}

/** 生成集群 CA */
function initCa(flags: Record<string, string>): void {
  const openssl = findOpenssl();
  const out = flags.out ?? './certs';
  const days = flags.days ?? '3650';
  const name = flags.name ?? 'RiJi Cluster CA';
  ensureDir(out);

  const keyPath = path.join(out, 'ca.key.pem');
  const certPath = path.join(out, 'ca.crt.pem');
  if (existsSync(keyPath)) fail(`CA 已存在：${keyPath}。如需重建请先删除该目录`);

  run(openssl, ['genrsa', '-out', keyPath, '2048']);
  run(openssl, [
    'req', '-x509', '-new', '-nodes', '-key', keyPath, '-sha256', '-days', days,
    '-out', certPath,
    '-subj', `/CN=${name}/O=RiJi/OU=Cluster CA`,
    '-addext', 'basicConstraints=critical,CA:TRUE,pathlen:0',
    '-addext', 'keyUsage=critical,keyCertSign,cRLSign',
    '-addext', 'subjectKeyIdentifier=hash',
  ]);

  console.log('');
  console.log(`✓ 集群 CA 已生成（有效期 ${days} 天）`);
  console.log(`  ${certPath}  —— 分发给所有节点`);
  console.log(`  ${keyPath}  —— 【务必离线保管】泄漏等于集群失守`);
}

/** 为节点签发证书 */
function issue(flags: Record<string, string>): void {
  const openssl = findOpenssl();
  const caDir = flags.ca ?? './certs';
  const out = flags.out ?? caDir;
  const name = flags.name;
  if (!name) fail('缺少 --name（节点标识，例如 node-1）');
  if (!/^[A-Za-z0-9._-]+$/.test(name)) fail('节点证书名只能是字母、数字、点、下划线、短横线');
  const days = flags.days ?? '825';

  const caKey = path.join(caDir, 'ca.key.pem');
  const caCert = path.join(caDir, 'ca.crt.pem');
  if (!existsSync(caKey) || !existsSync(caCert)) fail(`找不到 CA 文件（${caDir}）。先执行 init-ca。`);

  ensureDir(out);
  const keyPath = path.join(out, `${name}.key.pem`);
  const csrPath = path.join(out, `${name}.csr`);
  const crtPath = path.join(out, `${name}.crt.pem`);
  const extPath = path.join(out, `${name}.ext.cnf`);

  const hosts = (flags.hosts ?? '').split(',').map((h) => h.trim()).filter(Boolean);
  const sanEntries = [`DNS:${name}`];
  for (const host of hosts) {
    sanEntries.push(/^\d{1,3}(\.\d{1,3}){3}$/.test(host) ? `IP:${host}` : `DNS:${host}`);
  }

  writeFileSync(
    extPath,
    [
      'basicConstraints=critical,CA:FALSE',
      'keyUsage=critical,digitalSignature,keyEncipherment',
      'extendedKeyUsage=serverAuth,clientAuth',
      `subjectAltName=${sanEntries.join(',')}`,
      'subjectKeyIdentifier=hash',
      'authorityKeyIdentifier=keyid,issuer',
      '',
    ].join('\n'),
    'utf8',
  );

  run(openssl, ['genrsa', '-out', keyPath, '2048']);
  run(openssl, ['req', '-new', '-key', keyPath, '-out', csrPath, '-subj', `/CN=${name}/O=RiJi/OU=Cluster Node`]);
  run(openssl, [
    'x509', '-req', '-in', csrPath,
    '-CA', caCert, '-CAkey', caKey, '-CAcreateserial',
    '-out', crtPath, '-days', days, '-sha256',
    '-extfile', extPath,
  ]);

  // 清理中间文件，只留证书与私钥
  rmSync(csrPath, { force: true });
  rmSync(extPath, { force: true });

  console.log('');
  console.log(`✓ 节点证书已签发：${name}（有效期 ${days} 天）`);
  console.log(`  覆盖：${sanEntries.join(', ')}`);
  console.log(`  用途：serverAuth + clientAuth`);
  console.log(`  ${keyPath}`);
  console.log(`  ${crtPath}`);
}

/** 校验证书链 */
function verify(flags: Record<string, string>): void {
  const openssl = findOpenssl();
  const caDir = flags.ca ?? './certs';
  const certPath = flags.cert;
  if (!certPath) fail('缺少 --cert');

  const caCert = path.join(caDir, 'ca.crt.pem');
  if (!existsSync(caCert)) fail(`找不到 CA 证书：${caCert}`);

  const result = spawnSync(openssl, ['verify', '-CAfile', caCert, certPath], { encoding: 'utf8' });
  const ok = result.status === 0;

  const subject = run(openssl, ['x509', '-in', certPath, '-noout', '-subject']).trim();
  const dates = run(openssl, ['x509', '-in', certPath, '-noout', '-dates']).trim();

  console.log('');
  console.log(subject);
  console.log(dates.replace(/\n/g, '  '));
  console.log(`由本集群 CA 签发：${ok ? '✓ 是' : '✗ 否'}`);

  if (!ok) {
    console.error('');
    console.error('✗ 校验失败：该证书不能用于本集群');
    console.error(result.stderr?.trim() ?? '');
    process.exit(1);
  }
  console.log('');
  console.log('✓ 校验通过');
}

/** 展示证书内容 */
function show(flags: Record<string, string>): void {
  const openssl = findOpenssl();
  const certPath = flags.cert;
  if (!certPath) fail('缺少 --cert');
  const text = run(openssl, ['x509', '-in', certPath, '-noout', '-text']);
  for (const line of text.split('\n')) {
    if (/Subject:|Issuer:|Not Before|Not After|DNS:|IP Address|CA:|Key Usage|Certificate Sign|Client Authentication|TLS Web/.test(line)) {
      console.log(line.trim());
    }
  }
  void readFileSync;
}

const { command, flags } = parseArgs(process.argv.slice(2));
switch (command) {
  case 'init-ca':
    initCa(flags);
    break;
  case 'issue':
    issue(flags);
    break;
  case 'verify':
    verify(flags);
    break;
  case 'show':
    show(flags);
    break;
  default:
    console.log('用法：');
    console.log('  certs init-ca --out ./certs [--name "RiJi Cluster CA"] [--days 3650]');
    console.log('  certs issue   --ca ./certs --name node-1 [--hosts 10.0.0.1,node-1.internal] [--out ./certs]');
    console.log('  certs verify  --ca ./certs --cert ./certs/node-1.crt.pem');
    console.log('  certs show    --cert ./certs/node-1.crt.pem');
    process.exit(2);
}
