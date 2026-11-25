((request, url, payload, reply) => {
  const expected = JSON.parse(payload);
  const sameDocument = () => location.href === url && globalThis.__moonSiteDataRevision === String(expected.revision);
  let finished = false;
  function finish(state, data = {}) {
    if (!finished && sameDocument()) {
      const result = expected.clear ? { mutation: { ready: 'cleared', changed: 'conflict', unavailable: 'failed' }[state] } : { state, ...data };
      reply(request + '\n' + JSON.stringify(result));
    }
    finished = true;
  }

  const clip = (text, limit) => text.slice(0, limit).toWellFormed();
  function named(full) {
    const name = clip(full, 96);
    return { name, shortened: name !== full };
  }
  function keyPath(path) {
    if (path === null) return null;
    const compound = Array.isArray(path);
    const full = compound ? path : [path];
    const parts = full.slice(0, 4).map(part => clip(part, 48));
    return { parts, compound, shortened: parts.length !== full.length || parts.some((part, index) => part !== full[index]) };
  }
  function names(list, limit) {
    return Array.from({ length: Math.min(list.length, limit) }, (_, index) => list.item(index));
  }
  function inspectStructure(db) {
    const stores = [], encoder = new TextEncoder();
    const selected = names(db.objectStoreNames, 12);
    if (!selected.length) return { stores, more: false };
    const transaction = db.transaction(selected, 'readonly');
    let remaining = 18 * 1024;
    for (const name of selected) {
      const store = transaction.objectStore(name);
      const indexes = names(store.indexNames, 8).map(indexName => {
        const index = store.index(indexName);
        return { ...named(indexName), keyPath: keyPath(index.keyPath), unique: index.unique, multiEntry: index.multiEntry };
      });
      const item = { ...named(name), keyPath: keyPath(store.keyPath), autoIncrement: store.autoIncrement,
        indexes, more: store.indexNames.length > indexes.length };
      remaining -= encoder.encode(JSON.stringify(item)).length + 1;
      if (remaining < 0) break;
      stores.push(item);
    }
    return { stores, more: db.objectStoreNames.length > stores.length };
  }

  function preview(value, limit) {
    let shortened = false;
    const ancestors = new WeakSet();
    const trim = text => {
      const part = clip(text, limit);
      shortened ||= part !== text;
      return part;
    };
    const omit = text => {
      shortened = true;
      return text;
    };
    function format(item, depth) {
      if (item === null) return 'null';
      switch (typeof item) {
        case 'string': return JSON.stringify(trim(item));
        case 'number': return Object.is(item, -0) ? '-0' : String(item);
        case 'boolean':
        case 'undefined': return String(item);
        case 'bigint': return item < -(1n << 256n) || item > (1n << 256n) ? omit('BigInt') : String(item) + 'n';
      }
      if (item instanceof Date) return 'Date(' + (Number.isNaN(item.getTime()) ? '无效' : item.toISOString()) + ')';
      if (item instanceof RegExp) return '/' + trim(item.source) + '/' + item.flags;
      if (item instanceof Blob) return omit('Blob (' + item.size + ' bytes)');
      if (item instanceof ArrayBuffer || ArrayBuffer.isView(item)) {
        const size = item.byteLength;
        const bytes = item instanceof ArrayBuffer ? new Uint8Array(item, 0, Math.min(size, 8)) :
          new Uint8Array(item.buffer, item.byteOffset, Math.min(size, 8));
        const prefix = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join(' ');
        shortened ||= size > bytes.length;
        return 'Binary (' + size + ' bytes)' + (prefix ? ' ' + prefix : '');
      }
      if (item instanceof Map || item instanceof Set) return omit((item instanceof Map ? 'Map' : 'Set') + ' (' + item.size + ')');
      if (ancestors.has(item)) return omit('[循环引用]');
      const array = Array.isArray(item);
      const prototype = Object.getPrototypeOf(item);
      if (!array && prototype !== Object.prototype && prototype !== null) return omit('[其他对象]');
      if (depth >= 2) return omit(array ? '[…]' : '{…}');
      ancestors.add(item);
      const fields = [];
      if (array) {
        for (let i = 0; i < Math.min(item.length, 5); ++i) fields.push(format(item[i], depth + 1));
        shortened ||= item.length > fields.length;
      } else {
        for (const key in item) {
          if (!Object.hasOwn(item, key)) continue;
          if (fields.length === 6) { shortened = true; break; }
          fields.push(JSON.stringify(trim(key)) + ': ' + format(item[key], depth + 1));
        }
      }
      ancestors.delete(item);
      return (array ? '[' : '{') + fields.join(', ') + (array ? ']' : '}');
    }
    const text = trim(format(value, 0));
    return { text, shortened };
  }

  function inspectRecords(db, query) {
    if (!db.objectStoreNames.contains(query.store)) { finish('changed'); return; }
    const transaction = db.transaction([query.store], 'readonly');
    const cursor = transaction.objectStore(query.store).openCursor();
    const records = [];
    let skip = query.offset;
    cursor.onerror = () => finish('unavailable');
    transaction.onabort = () => finish('unavailable');
    cursor.onsuccess = () => {
      if (!sameDocument()) return;
      try {
        const row = cursor.result;
        if (!row || records.length === query.size) {
          const end = query.offset + records.length;
          finish('ready', { records, next: row && end < query.limit ? end : null, capped: !!row && end >= query.limit });
        } else if (skip > 0) {
          row.advance(skip);
          skip = 0;
        } else {
          records.push({ key: preview(row.key, 160), value: preview(row.value, 320) });
          row.continue();
        }
      } catch {
        finish('unavailable');
      }
    };
  }

  function clearStore(db, change) {
    if (!db.objectStoreNames.contains(change.store)) { finish('changed'); return; }
    if (Date.now() >= change.expires) { finish('unavailable'); return; }
    const transaction = db.transaction(change.store, 'readwrite');
    const abort = () => { try { transaction.abort(); } catch {} };
    const deadline = setTimeout(abort, Math.max(0, change.expires - Date.now()));
    transaction.onabort = () => { clearTimeout(deadline); finish('unavailable'); };
    transaction.oncomplete = () => { clearTimeout(deadline); finish('ready'); };
    try {
      const store = transaction.objectStore(change.store);
      // Recheck the document and deadline after any earlier writer releases this store.
      const probe = store.getKey(0);
      probe.onsuccess = () => {
        if (!sameDocument() || Date.now() >= change.expires) { abort(); return; }
        try { store.clear(); } catch { abort(); }
      };
    } catch { abort(); }
  }

  if (!sameDocument()) return;
  indexedDB.databases().then(databases => {
    if (!sameDocument()) return;
    if (!databases.some(db => db.name === expected.name && db.version === expected.version)) { finish('changed'); return; }
    if (expected.clear && Date.now() >= expected.clear.expires) { finish('unavailable'); return; }
    const open = indexedDB.open(expected.name);
    open.onupgradeneeded = () => { open.transaction.abort(); finish('changed'); };
    open.onerror = () => finish('unavailable');
    open.onsuccess = () => {
      const db = open.result;
      try {
        if (!sameDocument()) return;
        if (db.version !== expected.version) { finish('changed'); return; }
        if (expected.clear) clearStore(db, expected.clear);
        else if (expected.records) inspectRecords(db, expected.records);
        else finish('ready', inspectStructure(db));
      } catch {
        finish('unavailable');
      } finally {
        db.close();
      }
    };
  }).catch(() => finish('unavailable'));
})
