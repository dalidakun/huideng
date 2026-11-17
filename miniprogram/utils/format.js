function pad(n) {
  return n < 10 ? '0' + n : '' + n;
}

// 2026-10-30 16:20
function formatDate(ts) {
  const d = new Date(ts || Date.now());
  return (
    d.getFullYear() +
    '-' +
    pad(d.getMonth() + 1) +
    '-' +
    pad(d.getDate()) +
    ' ' +
    pad(d.getHours()) +
    ':' +
    pad(d.getMinutes())
  );
}

function formatChars(n) {
  const num = Number(n) || 0;
  if (num >= 10000) return (num / 10000).toFixed(1) + ' 万字';
  return num + ' 字';
}

module.exports = { formatDate, formatChars };
