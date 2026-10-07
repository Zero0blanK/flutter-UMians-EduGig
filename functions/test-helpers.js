/**
 * An in-memory stand-in for the Admin Firestore surface the backend uses:
 * documents, collections with equality/range filters, transactions, batches,
 * `increment` markers, and failure injection. Enough to run every route and
 * ledger operation offline and deterministically.
 */

const INC = Symbol('increment');

function increment(n) {
  return { [INC]: n };
}

function applyIncrements(existing, value) {
  const out = { ...(existing || {}) };
  for (const [key, v] of Object.entries(value)) {
    if (v && typeof v === 'object' && INC in v) {
      out[key] = (Number.isFinite(out[key]) ? out[key] : 0) + v[INC];
    } else if (key.includes('.')) {
      // Dotted paths: only one level deep is needed here.
      const [head, tail] = key.split('.');
      out[head] = { ...(out[head] || {}), [tail]: v };
    } else {
      out[key] = v;
    }
  }
  return out;
}

function fakeDb(seed = {}) {
  const docs = new Map(Object.entries(seed));
  let counter = 0;
  const db = {
    failNext: null,
    docs,
    doc(path) {
      const ref = {
        path,
        id: path.split('/').pop(),
        async get() {
          if (db.failNext === path) {
            db.failNext = null;
            throw new Error('firestore unavailable');
          }
          const data = docs.get(path);
          return { exists: data !== undefined, id: ref.id, data: () => data, ref };
        },
        async set(value, options) {
          if (db.failNext === path) {
            db.failNext = null;
            throw new Error('firestore unavailable');
          }
          docs.set(
            path,
            options?.merge ? applyIncrements(docs.get(path), value) : applyIncrements({}, value),
          );
        },
        async update(value) {
          if (!docs.has(path)) throw new Error(`no document to update at ${path}`);
          docs.set(path, applyIncrements(docs.get(path), value));
        },
        async delete() {
          docs.delete(path);
        },
      };
      return ref;
    },
    collection(path) {
      const filters = [];
      let limitTo = Infinity;
      const ordering = [];
      let afterDocument;
      const col = {
        path,
        doc(id) {
          return db.doc(`${path}/${id ?? `auto${++counter}`}`);
        },
        async add(value) {
          const ref = col.doc();
          await ref.set(value);
          return ref;
        },
        where(field, op, value) {
          filters.push({ field, op, value });
          return col;
        },
        orderBy(field, direction = 'asc') {
          ordering.push({ field, direction });
          return col;
        },
        startAfter(document) {
          afterDocument = document;
          return col;
        },
        limit(n) {
          limitTo = n;
          return col;
        },
        async get() {
          const prefix = `${path}/`;
          const matches = [];
          for (const [docPath, data] of docs) {
            if (!docPath.startsWith(prefix) || docPath.slice(prefix.length).includes('/')) {
              continue;
            }
            if (filters.every((f) => matchFilter(data, f))) {
              const ref = db.doc(docPath);
              matches.push({ id: ref.id, ref, exists: true, data: () => data });
            }
          }
          if (ordering.length) matches.sort((left, right) => {
            for (const { field, direction } of ordering) {
              const a = toComparable(left.data()[field]);
              const b = toComparable(right.data()[field]);
              if (a !== b) return (a < b ? -1 : 1) * (direction === 'desc' ? -1 : 1);
            }
            return left.id.localeCompare(right.id);
          });
          const offset = afterDocument ? matches.findIndex((doc) => doc.id === afterDocument.id) + 1 : 0;
          const page = matches.slice(offset, offset + limitTo);
          return { docs: page, empty: page.length === 0, size: page.length };
        },
      };
      return col;
    },
    async runTransaction(fn) {
      const tx = {
        get: (ref) => ref.get(),
        set: (ref, value, options) => {
          docs.set(
            ref.path,
            options?.merge
              ? applyIncrements(docs.get(ref.path), value)
              : applyIncrements({}, value),
          );
        },
        update: (ref, value) => {
          if (!docs.has(ref.path)) throw new Error(`no document to update at ${ref.path}`);
          docs.set(ref.path, applyIncrements(docs.get(ref.path), value));
        },
        delete: (ref) => docs.delete(ref.path),
      };
      return fn(tx);
    },
    batch() {
      const ops = [];
      const batch = {
        set: (ref, value, options) => ops.push(() => ref.set(value, options)),
        update: (ref, value) => ops.push(() => ref.update(value)),
        delete: (ref) => ops.push(() => ref.delete()),
        async commit() {
          for (const op of ops) await op();
        },
      };
      return batch;
    },
  };
  return db;
}

function matchFilter(data, { field, op, value }) {
  const actual = data?.[field];
  const a = toComparable(actual);
  const b = toComparable(value);
  switch (op) {
    case '==':
      return a === b;
    case '>':
      return a !== undefined && a > b;
    case '>=':
      return a !== undefined && a >= b;
    case '<':
      return a !== undefined && a < b;
    case '<=':
      return a !== undefined && a <= b;
    default:
      throw new Error(`unsupported operator ${op}`);
  }
}

function toComparable(value) {
  if (value instanceof Date) return value.getTime();
  if (value && typeof value.toDate === 'function') return value.toDate().getTime();
  return value;
}

/** Firestore's on-the-wire shape for a document that the fake stored. */
function docsOf(db, prefix) {
  return [...db.docs.entries()]
    .filter(([path]) => path.startsWith(`${prefix}/`))
    .map(([path, data]) => ({ path, ...data }));
}

const silentLogger = { error() {}, warn() {}, log() {} };

module.exports = { fakeDb, increment, docsOf, silentLogger };
