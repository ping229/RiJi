/* 日记平台 · 管理员后台（原生 JS，无构建步骤） */
(() => {
  'use strict';

  const TOKEN_KEY = 'riji_admin_token';
  const NAME_KEY = 'riji_admin_name';

  const $ = (sel) => document.querySelector(sel);
  const el = (tag, props = {}, children = []) => {
    const node = document.createElement(tag);
    Object.assign(node, props);
    for (const child of children) node.append(child);
    return node;
  };

  let token = localStorage.getItem(TOKEN_KEY) || '';

  // ---------------------------------------------------------------- 基础工具

  async function api(path, options = {}) {
    const headers = { 'content-type': 'application/json', ...(options.headers || {}) };
    if (token) headers.authorization = `Bearer ${token}`;
    // POST/PUT/DELETE 即使没有内容也要带空对象，否则服务端会因为空 body 返回 415
    const method = (options.method || 'GET').toUpperCase();
    const requestBody = options.body ?? (method === 'GET' ? undefined : '{}');
    const res = await fetch(path, { ...options, method, headers, body: requestBody });
    if (res.status === 401) {
      logout();
      throw new Error('登录已过期，请重新登录');
    }
    const text = await res.text();
    const body = text ? JSON.parse(text) : null;
    if (!res.ok) {
      const message = body?.error?.message || `请求失败（${res.status}）`;
      throw new Error(message);
    }
    return body;
  }

  function toast(message, isError = false) {
    const box = $('#toast');
    box.textContent = message;
    box.style.background = isError ? '#8f342e' : '#2f372c';
    box.hidden = false;
    clearTimeout(box._timer);
    box._timer = setTimeout(() => { box.hidden = true; }, 3200);
  }

  function fmtTime(iso) {
    if (!iso) return '—';
    const d = new Date(iso);
    if (Number.isNaN(d.getTime())) return iso;
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
  }

  function fmtBytes(bytes) {
    if (!bytes) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value = bytes;
    let i = 0;
    while (value >= 1024 && i < units.length - 1) { value /= 1024; i += 1; }
    return `${value.toFixed(value >= 10 || i === 0 ? 0 : 1)} ${units[i]}`;
  }

  function statusBadge(status) {
    const map = {
      active: ['活跃', 'ok'],
      disabled: ['已禁用', 'off'],
      pending_delete: ['待删除', 'warn'],
      online: ['在线', 'ok'],
      syncing: ['同步中', 'warn'],
      offline: ['离线', 'off'],
      failed: ['同步失败', 'off'],
      retiring: ['退役中', 'warn'],
      retired: ['已退役', 'off'],
    };
    const [label, cls] = map[status] || [status, ''];
    return el('span', { className: `badge ${cls}`, textContent: label });
  }

  // ------------------------------------------------------------------ 登录

  async function handleLogin(event) {
    event.preventDefault();
    const username = $('#login-username').value.trim();
    const password = $('#login-password').value;
    const errorBox = $('#login-error');
    errorBox.textContent = '';
    if (!username || !password) {
      errorBox.textContent = '请输入用户名和密码';
      return;
    }
    $('#login-submit').disabled = true;
    try {
      const res = await fetch('/api/auth/login', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ username, password, device: { name: '管理员控制台', platform: 'unknown' } }),
      });
      const body = await res.json();
      if (!res.ok) throw new Error(body?.error?.message || '登录失败');
      if (body.user.role !== 'admin') throw new Error('该账号不是管理员，无法登录后台');
      token = body.accessToken;
      localStorage.setItem(TOKEN_KEY, token);
      localStorage.setItem(NAME_KEY, body.user.username);
      enterShell();
    } catch (err) {
      errorBox.textContent = err.message;
    } finally {
      $('#login-submit').disabled = false;
    }
  }

  function logout() {
    token = '';
    localStorage.removeItem(TOKEN_KEY);
    localStorage.removeItem(NAME_KEY);
    $('#shell').hidden = true;
    $('#login').hidden = false;
    $('#login-password').value = '';
  }

  function enterShell() {
    $('#login').hidden = true;
    $('#shell').hidden = false;
    $('#admin-name').textContent = `管理员：${localStorage.getItem(NAME_KEY) || ''}`;
    loadStats();
  }

  // ------------------------------------------------------------------ 概览

  async function loadStats() {
    try {
      const s = await api('/api/admin/stats');
      const cards = [
        ['用户', s.users, `${s.usersDisabled} 个非活跃`],
        ['日记', s.diaries, `${s.blocks} 个块`],
        ['媒体', s.mediaCount, fmtBytes(s.mediaBytes)],
        ['节点', s.nodes, `${s.nodesOnline} 个在线`],
        ['审计记录', s.auditEntries, '不可删除'],
      ];
      const grid = $('#stats');
      grid.innerHTML = '';
      for (const [label, value, sub] of cards) {
        grid.append(el('div', { className: 'stat' }, [
          el('div', { className: 'label', textContent: label }),
          el('div', { className: 'value', textContent: String(value) }),
          el('div', { className: 'sub', textContent: sub }),
        ]));
      }
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function runConsistency() {
    const box = $('#consistency-result');
    box.textContent = '正在校验…';
    try {
      const res = await api('/api/admin/consistency', { method: 'POST' });
      box.textContent = JSON.stringify(res.summary, null, 2);
      toast('一致性校验完成');
    } catch (err) {
      box.textContent = '';
      toast(err.message, true);
    }
  }

  // ------------------------------------------------------------------ 用户

  /** 字节转可读 */
  function fmtBytes(bytes) {
    const n = Number(bytes || 0);
    if (!n) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let value = n;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1; }
    return `${value.toFixed(value >= 100 || unit === 0 ? 0 : 1)} ${units[unit]}`;
  }

  /** 存储用量：进度条 + 文字，快满时变红 */
  function storageCell(u) {
    const used = Number(u.usedBytes || 0);
    const quota = u.quotaBytes === null || u.quotaBytes === undefined ? null : Number(u.quotaBytes);
    if (quota === null) {
      return el('span', { className: 'muted', textContent: `${fmtBytes(used)} / 不限` });
    }
    const pct = quota > 0 ? Math.min(100, (used / quota) * 100) : 0;
    const cls = pct >= 95 ? 'badge-danger' : pct >= 80 ? 'badge-warn' : 'badge-ok';
    const wrap = el('div', {});
    wrap.append(el('div', { textContent: `${fmtBytes(used)} / ${fmtBytes(quota)}` }));
    const bar = el('div', { style: 'height:4px;border-radius:2px;background:#eee;margin-top:4px;width:110px;overflow:hidden' });
    const fill = el('div', {
      style: `height:100%;width:${pct}%;background:${pct >= 95 ? '#b3261e' : pct >= 80 ? '#a35c00' : '#1e7e34'}`,
    });
    bar.append(fill);
    wrap.append(bar);
    wrap.append(el('span', { className: `badge ${cls}`, textContent: `${pct.toFixed(0)}%` }));
    return wrap;
  }

  /** 调整某用户的配额 */
  async function editQuota(user) {
    const currentGb = user.quotaBytes ? (Number(user.quotaBytes) / 1024 / 1024 / 1024).toFixed(1) : '0';
    const input = prompt(
      `给「${user.username}」设置存储配额（GB）。\n\n填 0 表示不限制。\n当前用量：${fmtBytes(user.usedBytes)}`,
      currentGb,
    );
    if (input === null) return;
    const gb = Number(input);
    if (!Number.isFinite(gb) || gb < 0) {
      toast('请输入不小于 0 的数字', true);
      return;
    }
    try {
      await api(`/api/admin/users/${user.id}/quota`, {
        method: 'PATCH',
        body: JSON.stringify({ quotaGb: gb }),
      });
      toast(gb === 0 ? '已设为不限制' : `已设置为 ${gb} GB`);
      loadUsers();
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function loadUsers() {
    try {
      const query = encodeURIComponent($('#user-query').value.trim());
      const status = encodeURIComponent($('#user-status').value);
      const res = await api(`/api/admin/users?query=${query}&status=${status}`);
      const tbody = $('#user-rows');
      tbody.innerHTML = '';
      if (res.users.length === 0) {
        tbody.append(el('tr', {}, [el('td', { colSpan: 8, textContent: '没有匹配的用户', className: 'muted' })]));
        return;
      }
      for (const u of res.users) {
        const actions = el('div', { className: 'row-actions' });
        if (u.status === 'active') {
          actions.append(el('button', {
            textContent: '禁用',
            onclick: () => userAction(u, 'disable'),
          }));
        } else {
          actions.append(el('button', {
            textContent: '启用',
            onclick: () => userAction(u, 'enable'),
          }));
        }
        actions.append(el('button', {
          textContent: '配额',
          onclick: () => editQuota(u),
        }));
        actions.append(el('button', {
          textContent: '删除',
          className: 'danger',
          onclick: () => deleteUser(u),
        }));

        tbody.append(el('tr', {}, [
          el('td', { textContent: u.username }),
          el('td', { textContent: u.role === 'admin' ? '管理员' : '普通用户' }),
          el('td', {}, [statusBadge(u.status)]),
          el('td', { textContent: String(u.diaryCount) }),
          el('td', { textContent: String(u.blockCount) }),
          el('td', {}, [storageCell(u)]),
          el('td', { textContent: fmtTime(u.lastActiveAt) }),
          el('td', {}, [actions]),
        ]));
      }
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function userAction(user, action) {
    const label = action === 'disable' ? '禁用' : '启用';
    if (!confirm(`确定要${label}用户「${user.username}」吗？`)) return;
    try {
      await api(`/api/admin/users/${user.id}/${action}`, { method: 'POST' });
      toast(`${label}成功`);
      loadUsers();
      loadStats();
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function deleteUser(user) {
    const typed = prompt(
      `删除用户不可恢复，会清空该用户在所有节点上的日记与媒体。\n请输入用户名「${user.username}」以确认：`,
    );
    if (typed === null) return;
    if (typed !== user.username) {
      toast('用户名不匹配，已取消', true);
      return;
    }
    try {
      await api(`/api/admin/users/${user.id}`, {
        method: 'DELETE',
        body: JSON.stringify({ confirmUsername: typed }),
      });
      toast('用户已删除');
      loadUsers();
      loadStats();
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function handleCreateUser(event) {
    event.preventDefault();
    try {
      await api('/api/admin/users', {
        method: 'POST',
        body: JSON.stringify({
          username: $('#new-username').value.trim(),
          password: $('#new-password').value,
          role: $('#new-role').value,
          quotaGb: Number($('#new-quota').value || 0),
        }),
      });
      $('#new-username').value = '';
      $('#new-password').value = '';
      toast('用户已创建（默认 5GB 配额，可在列表里调整）');
      loadUsers();
      loadStats();
    } catch (err) {
      toast(err.message, true);
    }
  }

  // ------------------------------------------------------------------ 节点

  /** 同步进度：落后条数 + 状态色 */
  function lagBadge(n) {
    if (n.role === 'primary') return el('span', { className: 'muted', textContent: '—' });
    const lag = Number(n.replicationLag || 0);
    if (n.fullSyncRequestedAt && !n.fullSyncStartedAt) {
      return el('span', { className: 'badge badge-warn', textContent: '等待开始全量同步' });
    }
    if (n.fullSyncStartedAt && lag > 0) {
      return el('span', { className: 'badge badge-warn', textContent: `全量同步中，落后 ${lag}` });
    }
    if (lag === 0) return el('span', { className: 'badge badge-ok', textContent: '已同步' });
    const cls = lag > 100 ? 'badge-danger' : 'badge-warn';
    return el('span', { className: `badge ${cls}`, textContent: `落后 ${lag}` });
  }

  async function fullSync(node) {
    if (!confirm(`对节点「${node.id}」执行全量同步？\n\n它的游标会清零并重新拉取全部数据。\n数据不会重复，但过程中该节点写入会排队。`)) return;
    try {
      await api(`/api/admin/nodes/${node.id}/full-sync`, { method: 'POST' });
      toast('已下发全量同步指令，副本将在下次心跳时开始');
      loadNodes();
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function loadNodes() {
    try {
      const res = await api('/api/admin/nodes');
      const tbody = $('#node-rows');
      tbody.innerHTML = '';
      for (const n of res.nodes) {
        const actions = el('div', { className: 'row-actions' });
        if (n.status === 'disabled' || n.status === 'offline') {
          actions.append(el('button', { textContent: '启用', onclick: () => nodeAction(n, 'enable', '启用') }));
        } else if (n.status !== 'retiring' && n.status !== 'retired') {
          actions.append(el('button', { textContent: '禁用', onclick: () => nodeAction(n, 'disable', '禁用') }));
        }
        if (n.role === 'replica' && n.status !== 'retired' && n.status !== 'disabled') {
          actions.append(el('button', { textContent: '提升为主', onclick: () => promote(n) }));
          actions.append(el('button', {
            textContent: '全量同步',
            onclick: () => fullSync(n),
          }));
        }
        if (n.status === 'retiring') {
          actions.append(el('button', {
            textContent: '确认退役',
            className: 'danger',
            onclick: () => nodeAction(n, 'retire/finalize', '确认退役'),
          }));
        } else if (n.status !== 'retired') {
          actions.append(el('button', {
            textContent: '准备退役',
            className: 'danger',
            onclick: () => retire(n),
          }));
        }

        tbody.append(el('tr', {}, [
          el('td', { textContent: n.id }),
          el('td', { textContent: n.role === 'primary' ? '主节点' : '副本' }),
          el('td', {}, [statusBadge(n.status)]),
          el('td', { textContent: String(n.epoch) }),
          el('td', {}, [lagBadge(n)]),
          el('td', { textContent: fmtTime(n.lastHeartbeatAt) }),
          el('td', {}, [actions]),
        ]));
      }
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function nodeAction(node, path, label) {
    if (!confirm(`确定要对节点「${node.id}」执行${label}吗？`)) return;
    try {
      await api(`/api/admin/nodes/${node.id}/${path}`, { method: 'POST' });
      toast(`${label}成功`);
      loadNodes();
      loadStats();
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function promote(node) {
    if (!confirm(`把「${node.id}」提升为主节点？原主节点会降级为副本，epoch 将递增。`)) return;
    try {
      await api(`/api/admin/nodes/${node.id}/promote`, { method: 'POST' });
      toast('已提升为主节点');
      loadNodes();
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function retire(node) {
    if (!confirm(`准备退役节点「${node.id}」？系统会先检查数据是否在其他节点有完整副本。`)) return;
    try {
      const res = await api(`/api/admin/nodes/${node.id}/retire`, { method: 'POST' });
      toast(`已进入退役中，集群剩余 ${res.remaining} 个节点`);
      loadNodes();
      loadStats();
    } catch (err) {
      toast(err.message, true);
    }
  }

  async function handleAddNode(event) {
    event.preventDefault();
    try {
      await api('/api/admin/nodes', {
        method: 'POST',
        body: JSON.stringify({
          id: $('#node-id').value.trim(),
          endpoint: $('#node-endpoint').value.trim(),
          role: $('#node-role').value,
        }),
      });
      $('#node-id').value = '';
      $('#node-endpoint').value = '';
      toast('节点已加入，正在同步');
      loadNodes();
      loadStats();
    } catch (err) {
      toast(err.message, true);
    }
  }

  // ------------------------------------------------------------------ 审计

  async function loadAudit() {
    try {
      const res = await api('/api/admin/audit?limit=200');
      const tbody = $('#audit-rows');
      tbody.innerHTML = '';
      if (res.entries.length === 0) {
        tbody.append(el('tr', {}, [el('td', { colSpan: 5, textContent: '还没有审计记录', className: 'muted' })]));
        return;
      }
      for (const e of res.entries) {
        tbody.append(el('tr', {}, [
          el('td', { textContent: fmtTime(e.createdAt) }),
          el('td', { textContent: e.actorName || '系统' }),
          el('td', { textContent: e.action }),
          el('td', { textContent: `${e.targetType || ''} ${e.targetId || ''}`.trim() }),
          el('td', { textContent: JSON.stringify(e.detail), title: JSON.stringify(e.detail) }),
        ]));
      }
    } catch (err) {
      toast(err.message, true);
    }
  }

  // ------------------------------------------------------------------ 导航

  const loaders = {
    overview: () => { loadStats(); },
    users: loadUsers,
    nodes: loadNodes,
    audit: loadAudit,
  };

  function switchTab(name) {
    document.querySelectorAll('.nav-item').forEach((btn) => {
      btn.classList.toggle('active', btn.dataset.tab === name);
    });
    document.querySelectorAll('.tab').forEach((section) => {
      section.hidden = section.id !== `tab-${name}`;
    });
    loaders[name]?.();
  }

  function bind() {
    $('#login-form').addEventListener('submit', handleLogin);
    $('#logout').addEventListener('click', logout);
    document.querySelectorAll('.nav-item').forEach((btn) => {
      btn.addEventListener('click', () => switchTab(btn.dataset.tab));
    });
    $('#create-user-form').addEventListener('submit', handleCreateUser);
    $('#add-node-form').addEventListener('submit', handleAddNode);
    $('#user-search').addEventListener('click', loadUsers);
    $('#node-refresh').addEventListener('click', loadNodes);
    $('#audit-refresh').addEventListener('click', loadAudit);
    $('#btn-consistency').addEventListener('click', runConsistency);
  }

  bind();
  if (token) {
    enterShell();
    switchTab('overview');
  } else {
    $('#login').hidden = false;
  }
})();
