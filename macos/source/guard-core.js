/* Shared production state machine: loaded by macOS JavaScriptCore and Node tests. */
(function (root) {
  'use strict';
  function Engine(delay, stale, threshold) {
    this.delay = delay; this.stale = stale; this.threshold = threshold;
    this.lastSeen = null; this.samples = []; this.nearCount = 0;
    this.armed = false; this.latched = false; this.lostSince = null;
  }
  Engine.prototype.observe = function (now, rssi) {
    if (!Number.isFinite(now) || !Number.isFinite(rssi) || rssi >= 0 || rssi < -127) return false;
    if (this.lastSeen !== null && now < this.lastSeen) return false;
    if (this.lastSeen === null || now - this.lastSeen > this.stale) {
      this.samples = []; this.nearCount = 0;
    }
    this.lastSeen = now;
    this.samples.push(rssi); if (this.samples.length > 5) this.samples.shift();
    var mean = this.samples.reduce(function (a, b) { return a + b; }, 0) / this.samples.length;
    var limit = this.threshold === null ? null : this.threshold + (this.latched ? 5 : 0);
    if (limit === null || mean >= limit) {
      this.lostSince = null;
      this.nearCount++;
      if (this.nearCount >= 2) { this.armed = true; this.latched = false; }
    } else {
      this.nearCount = 0;
      if (this.armed && this.lostSince === null) this.lostSince = now;
    }
    return true;
  };
  Engine.prototype.tick = function (now) {
    var age = this.lastSeen === null ? null : Math.max(0, now - this.lastSeen);
    if (this.armed && age > this.stale) {
      this.nearCount = 0;
      if (this.lostSince === null) this.lostSince = this.lastSeen + this.stale;
    }
    var elapsed = this.lostSince === null ? 0 : Math.max(0, now - this.lostSince);
    var trigger = this.armed && !this.latched && this.lostSince !== null && elapsed >= this.delay;
    if (trigger) this.latched = true;
    return { armed: this.armed, latched: this.latched, trigger: trigger,
      age: age, elapsed: elapsed,
      state: !this.armed ? 'waiting' : this.latched ? 'away' : this.lostSince !== null ? 'countdown' : 'near' };
  };
  root.GuardCore = { Engine: Engine };
})(typeof globalThis !== 'undefined' ? globalThis : this);
