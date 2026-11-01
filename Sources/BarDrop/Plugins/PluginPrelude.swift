import Foundation

/// Bausteine, die Plugin-Autoren aus Browsern und Node kennen und die JavaScriptCore nicht
/// mitbringt: `URL`, `URLSearchParams`, `setTimeout`/`setInterval`, `queueMicrotask`,
/// `TextEncoder`/`TextDecoder`, `atob`/`btoa`, dazu Binärdaten über `bardrop.readData`
/// und `bardrop.writeData`. Jeder Baustein wird nur angelegt, wenn es ihn noch nicht gibt
/// (eine neuere JavaScriptCore bringt manche selbst mit).
///
/// Läuft vor dem Skript des Plugins, nach `installAPI` (braucht `bardrop.sleep`,
/// `__bardropParseURL`, `__bardropReadData`, `__bardropWriteData`, `__bardropFail`).
enum PluginPrelude {
    static let source = #"""
    (function (g) {
      'use strict';
      function define(name, value) {
        if (typeof g[name] === 'undefined') {
          Object.defineProperty(g, name, { value: value, writable: true, configurable: true, enumerable: false });
        }
      }

      // MARK: Zeitgeber (über bardrop.sleep). Ein Fehler in einem Rückruf lässt den Lauf scheitern
      var timers = {}, nextTimer = 1;
      function fire(fn, args) {
        try { if (typeof fn === 'function') fn.apply(undefined, args); }
        catch (e) { __bardropFail(e); }
      }
      define('setTimeout', function (fn, ms) {
        var id = nextTimer++, args = Array.prototype.slice.call(arguments, 2);
        timers[id] = true;
        bardrop.sleep(Math.max(0, Number(ms) || 0)).then(function () {
          if (!timers[id]) return;
          delete timers[id];
          fire(fn, args);
        });
        return id;
      });
      define('setInterval', function (fn, ms) {
        var id = nextTimer++, args = Array.prototype.slice.call(arguments, 2);
        var wait = Math.max(1, Number(ms) || 0);
        timers[id] = true;
        (function tick() {
          bardrop.sleep(wait).then(function () {
            if (!timers[id]) return;
            fire(fn, args);
            // Hat der Rückruf das Intervall beendet, nicht noch einmal warten (wie Node)
            if (timers[id]) tick();
          });
        })();
        return id;
      });
      define('clearTimeout', function (id) { delete timers[id]; });
      define('clearInterval', function (id) { delete timers[id]; });
      define('queueMicrotask', function (fn) {
        Promise.resolve().then(function () { fire(fn, []); });
      });

      // MARK: Base64
      var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      var B64_LOOKUP = new Int16Array(256).fill(-1);
      for (var i = 0; i < 64; i++) B64_LOOKUP[B64.charCodeAt(i)] = i;
      B64_LOOKUP[45] = 62; B64_LOOKUP[95] = 63;   // auch die URL-Fassung (- und _)

      function bytesToBase64(bytes) {
        var out = '', chunk = [], n = bytes.length, i = 0;
        for (; i + 2 < n; i += 3) {
          var v = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
          chunk.push(B64[v >> 18], B64[(v >> 12) & 63], B64[(v >> 6) & 63], B64[v & 63]);
          if (chunk.length >= 8192) { out += chunk.join(''); chunk = []; }
        }
        if (i < n) {
          var a = bytes[i], b = i + 1 < n ? bytes[i + 1] : 0;
          var w = (a << 16) | (b << 8);
          chunk.push(B64[w >> 18], B64[(w >> 12) & 63], i + 1 < n ? B64[(w >> 6) & 63] : '=', '=');
        }
        return out + chunk.join('');
      }

      function base64ToBytes(text) {
        var clean = String(text).replace(/[\s=]/g, '');
        var out = new Uint8Array(Math.floor(clean.length * 3 / 4));
        var buffer = 0, bits = 0, o = 0;
        for (var i = 0; i < clean.length; i++) {
          var v = clean.charCodeAt(i) < 256 ? B64_LOOKUP[clean.charCodeAt(i)] : -1;
          if (v < 0) throw new TypeError('Invalid Base64 text.');
          buffer = (buffer << 6) | v; bits += 6;
          if (bits >= 8) { bits -= 8; out[o++] = (buffer >> bits) & 255; }
        }
        return o === out.length ? out : out.slice(0, o);
      }

      define('btoa', function (text) {
        var s = String(text), bytes = new Uint8Array(s.length);
        for (var i = 0; i < s.length; i++) {
          var c = s.charCodeAt(i);
          if (c > 255) throw new TypeError('btoa: the text contains characters outside Latin-1. Use TextEncoder first.');
          bytes[i] = c;
        }
        return bytesToBase64(bytes);
      });
      define('atob', function (text) {
        var bytes = base64ToBytes(text), parts = [];
        for (var i = 0; i < bytes.length; i += 8192) {
          parts.push(String.fromCharCode.apply(null, bytes.subarray(i, i + 8192)));
        }
        return parts.join('');
      });

      // MARK: Text ↔ UTF-8
      function toBytes(input) {
        if (input instanceof Uint8Array) return input;
        if (input instanceof ArrayBuffer) return new Uint8Array(input);
        if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
        if (Array.isArray(input)) return Uint8Array.from(input);
        return null;
      }

      function utf8Encode(text) {
        var s = String(text), out = new Uint8Array(s.length * 3), o = 0;
        for (var i = 0; i < s.length; i++) {
          var c = s.charCodeAt(i);
          if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
            var d = s.charCodeAt(i + 1);
            if (d >= 0xDC00 && d <= 0xDFFF) { c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00); i++; }
            else c = 0xFFFD;
          } else if (c >= 0xD800 && c <= 0xDFFF) {
            c = 0xFFFD;
          }
          if (c < 0x80) out[o++] = c;
          else if (c < 0x800) { out[o++] = 0xC0 | (c >> 6); out[o++] = 0x80 | (c & 63); }
          else if (c < 0x10000) { out[o++] = 0xE0 | (c >> 12); out[o++] = 0x80 | ((c >> 6) & 63); out[o++] = 0x80 | (c & 63); }
          else { out[o++] = 0xF0 | (c >> 18); out[o++] = 0x80 | ((c >> 12) & 63); out[o++] = 0x80 | ((c >> 6) & 63); out[o++] = 0x80 | (c & 63); }
        }
        return out.slice(0, o);
      }

      function utf8Decode(bytes, fatal, keepBOM) {
        var parts = [], codes = [], i = 0, n = bytes.length;
        if (!keepBOM && n >= 3 && bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF) i = 3;
        function bad() {
          if (fatal) throw new TypeError('The data is not valid UTF-8.');
          codes.push(0xFFFD);
        }
        while (i < n) {
          var b = bytes[i], need = 0, c = 0, min = 0;
          if (b < 0x80) { codes.push(b); i++; }
          else {
            if (b >= 0xC2 && b <= 0xDF) { need = 1; c = b & 31; min = 0x80; }
            else if (b >= 0xE0 && b <= 0xEF) { need = 2; c = b & 15; min = 0x800; }
            else if (b >= 0xF0 && b <= 0xF4) { need = 3; c = b & 7; min = 0x10000; }
            else { bad(); i++; need = -1; }
            if (need > 0) {
              var j = 1;
              for (; j <= need; j++) {
                var x = bytes[i + j];
                if (i + j >= n || (x & 0xC0) !== 0x80) break;
                c = (c << 6) | (x & 63);
              }
              if (j <= need || c < min || c > 0x10FFFF || (c >= 0xD800 && c <= 0xDFFF)) { bad(); i += Math.max(1, j); }
              else {
                if (c >= 0x10000) { c -= 0x10000; codes.push(0xD800 + (c >> 10), 0xDC00 + (c & 1023)); }
                else codes.push(c);
                i += need + 1;
              }
            }
          }
          if (codes.length >= 8192) { parts.push(String.fromCharCode.apply(null, codes)); codes = []; }
        }
        parts.push(String.fromCharCode.apply(null, codes));
        return parts.join('');
      }

      function TextEncoder() {}
      Object.defineProperty(TextEncoder.prototype, 'encoding', { get: function () { return 'utf-8'; } });
      TextEncoder.prototype.encode = function (text) { return utf8Encode(text === undefined ? '' : text); };
      TextEncoder.prototype.encodeInto = function (text, target) {
        var bytes = utf8Encode(text), written = Math.min(bytes.length, target.length);
        // Nicht mitten in einem Zeichen abschneiden
        while (written > 0 && written < bytes.length && (bytes[written] & 0xC0) === 0x80) written--;
        target.set(bytes.subarray(0, written));
        var read = utf8Decode(bytes.subarray(0, written), false, true).length;
        return { read: read, written: written };
      };
      define('TextEncoder', TextEncoder);

      function TextDecoder(label, options) {
        var name = String(label === undefined ? 'utf-8' : label).trim().toLowerCase();
        if (name !== 'utf-8' && name !== 'utf8' && name !== 'unicode-1-1-utf-8') {
          throw new RangeError('TextDecoder: only UTF-8 is supported.');
        }
        this.fatal = !!(options && options.fatal);
        this.ignoreBOM = !!(options && options.ignoreBOM);
      }
      Object.defineProperty(TextDecoder.prototype, 'encoding', { get: function () { return 'utf-8'; } });
      TextDecoder.prototype.decode = function (input) {
        if (input === undefined) return '';
        var bytes = toBytes(input);
        if (!bytes) throw new TypeError('TextDecoder.decode needs an ArrayBuffer or a typed array.');
        return utf8Decode(bytes, this.fatal, this.ignoreBOM);
      };
      define('TextDecoder', TextDecoder);

      // MARK: URLSearchParams
      function formEncode(s) {
        return encodeURIComponent(s).replace(/%20/g, '+')
          .replace(/[!'()~]/g, function (c) { return '%' + c.charCodeAt(0).toString(16).toUpperCase(); });
      }
      function formDecode(s) {
        var plus = s.replace(/\+/g, ' ');
        try { return decodeURIComponent(plus); } catch (e) { return plus; }
      }

      class URLSearchParams {
        constructor(init) {
          this._list = [];
          this._url = null;
          if (init === undefined || init === null) return;
          if (init instanceof URLSearchParams) {
            this._list = init._list.map(function (p) { return [p[0], p[1]]; });
          } else if (typeof init === 'object' && typeof init[Symbol.iterator] === 'function') {
            for (const pair of init) {
              const a = Array.from(pair);
              if (a.length !== 2) throw new TypeError('URLSearchParams: each pair needs a name and a value.');
              this._list.push([String(a[0]), String(a[1])]);
            }
          } else if (typeof init === 'object') {
            for (const key of Object.keys(init)) this._list.push([key, String(init[key])]);
          } else {
            this._parse(String(init));
          }
        }
        _parse(text) {
          this._list = [];
          var s = text.charAt(0) === '?' ? text.slice(1) : text;
          for (const part of s.split('&')) {
            if (!part) continue;
            const i = part.indexOf('=');
            this._list.push(i < 0 ? [formDecode(part), ''] : [formDecode(part.slice(0, i)), formDecode(part.slice(i + 1))]);
          }
        }
        _changed() {
          if (this._url) {
            const s = this.toString();
            this._url._p.search = s ? '?' + s : '';
          }
        }
        get size() { return this._list.length; }
        append(name, value) { this._list.push([String(name), String(value)]); this._changed(); }
        delete(name, value) {
          name = String(name);
          this._list = this._list.filter(function (p) { return !(p[0] === name && (value === undefined || p[1] === String(value))); });
          this._changed();
        }
        get(name) {
          name = String(name);
          const found = this._list.find(function (p) { return p[0] === name; });
          return found ? found[1] : null;
        }
        getAll(name) {
          name = String(name);
          return this._list.filter(function (p) { return p[0] === name; }).map(function (p) { return p[1]; });
        }
        has(name, value) {
          name = String(name);
          return this._list.some(function (p) { return p[0] === name && (value === undefined || p[1] === String(value)); });
        }
        set(name, value) {
          name = String(name); value = String(value);
          const i = this._list.findIndex(function (p) { return p[0] === name; });
          if (i < 0) { this._list.push([name, value]); }
          else {
            this._list[i][1] = value;
            this._list = this._list.filter(function (p, j) { return j <= i || p[0] !== name; });
          }
          this._changed();
        }
        sort() {
          this._list.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0; });
          this._changed();
        }
        forEach(fn, thisArg) {
          for (const p of this._list.slice()) fn.call(thisArg, p[1], p[0], this);
        }
        keys() { return this._list.map(function (p) { return p[0]; })[Symbol.iterator](); }
        values() { return this._list.map(function (p) { return p[1]; })[Symbol.iterator](); }
        entries() { return this._list.map(function (p) { return [p[0], p[1]]; })[Symbol.iterator](); }
        [Symbol.iterator]() { return this.entries(); }
        toString() {
          return this._list.map(function (p) { return formEncode(p[0]) + '=' + formEncode(p[1]); }).join('&');
        }
      }
      define('URLSearchParams', URLSearchParams);

      // MARK: URL (zerlegt von Foundation)
      var SPECIAL = { 'http:': '80', 'https:': '443', 'ftp:': '21', 'ws:': '80', 'wss:': '443', 'file:': '' };
      function parse(input, base) {
        var p = __bardropParseURL(String(input), base === undefined || base === null ? undefined : String(base));
        if (!p) throw new TypeError('Invalid URL: ' + input);
        if (SPECIAL[p.protocol] !== undefined && p.port === SPECIAL[p.protocol]) p.port = '';
        if (SPECIAL[p.protocol] !== undefined && !p.pathname) p.pathname = '/';
        return p;
      }

      class URL {
        constructor(input, base) {
          if (input instanceof URL) input = input.href;
          if (base instanceof URL) base = base.href;
          this._p = parse(input, base);
          this._params = null;
        }
        static canParse(input, base) {
          try { new URL(input, base); return true; } catch (e) { return false; }
        }
        static parse(input, base) {
          try { return new URL(input, base); } catch (e) { return null; }
        }
        _reparse(href) {
          this._p = parse(href);
          if (this._params) this._params._parse(this._p.search);
        }
        get href() {
          var p = this._p;
          var auth = p.username ? p.username + (p.password ? ':' + p.password : '') + '@' : '';
          var authority = (p.hostname || SPECIAL[p.protocol] !== undefined) ? '//' + auth + p.hostname + (p.port ? ':' + p.port : '') : '';
          return p.protocol + authority + p.pathname + p.search + p.hash;
        }
        set href(value) { this._reparse(String(value)); }
        get origin() {
          var p = this._p;
          return (p.protocol === 'http:' || p.protocol === 'https:' || p.protocol === 'ws:' || p.protocol === 'wss:' || p.protocol === 'ftp:')
            ? p.protocol + '//' + this.host : 'null';
        }
        get protocol() { return this._p.protocol; }
        set protocol(value) {
          var s = String(value).replace(/:.*$/, '').toLowerCase();
          if (/^[a-z][a-z0-9+.-]*$/.test(s)) this._reparse(s + ':' + this.href.slice(this._p.protocol.length));
        }
        get username() { return this._p.username; }
        set username(value) { this._p.username = encodeURIComponent(String(value)); }
        get password() { return this._p.password; }
        set password(value) { this._p.password = encodeURIComponent(String(value)); }
        get host() { return this._p.hostname + (this._p.port ? ':' + this._p.port : ''); }
        set host(value) {
          var m = /^([^:\/?#]*)(?::(\d*))?/.exec(String(value));
          if (m && m[1]) { this._p.hostname = m[1].toLowerCase(); if (m[2] !== undefined) this.port = m[2]; }
        }
        get hostname() { return this._p.hostname; }
        set hostname(value) { var h = String(value).toLowerCase(); if (h && !/[\/?#:]/.test(h)) this._p.hostname = h; }
        get port() { return this._p.port; }
        set port(value) {
          var s = String(value).replace(/\D.*$/, '');
          this._p.port = SPECIAL[this._p.protocol] === s ? '' : s;
        }
        get pathname() { return this._p.pathname; }
        set pathname(value) {
          var s = String(value).replace(/[ "<>`#?{}]/g, function (c) { return encodeURIComponent(c); });
          if (this._p.hostname && s.charAt(0) !== '/') s = '/' + s;
          this._p.pathname = s;
        }
        get search() { return this._p.search === '?' ? '' : this._p.search; }
        set search(value) {
          var s = String(value);
          if (s.charAt(0) === '?') s = s.slice(1);
          s = s.replace(/[ "<>`#]/g, function (c) { return encodeURIComponent(c); });
          this._p.search = s ? '?' + s : '';
          if (this._params) this._params._parse(this._p.search);
        }
        get searchParams() {
          if (!this._params) {
            this._params = new URLSearchParams(this._p.search);
            this._params._url = this;
          }
          return this._params;
        }
        get hash() { return this._p.hash === '#' ? '' : this._p.hash; }
        set hash(value) {
          var s = String(value);
          if (s.charAt(0) === '#') s = s.slice(1);
          s = s.replace(/[ "<>`]/g, function (c) { return encodeURIComponent(c); });
          this._p.hash = s ? '#' + s : '';
        }
        toString() { return this.href; }
        toJSON() { return this.href; }
      }
      define('URL', URL);

      // MARK: Binärdaten
      bardrop.readData = function (path) { return base64ToBytes(__bardropReadData(path)); };
      bardrop.writeData = function (name, data) {
        var text;
        if (typeof data === 'string') {
          text = data;
        } else {
          var bytes = toBytes(data);
          if (!bytes) throw new TypeError('writeData needs a Uint8Array, an ArrayBuffer, a list of bytes or Base64 text.');
          text = bytesToBase64(bytes);
        }
        return __bardropWriteData(name, text);
      };
    })(globalThis);
    """#
}
