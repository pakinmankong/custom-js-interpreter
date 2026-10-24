import type Env from "./env.js";
import { createRequire } from "node:module";

const jStat = createRequire(import.meta.url)("jstat") as {
  studentt: { inv: (probability: number, degreesOfFreedom: number) => number };
};

function flattenValues(values: any[]): any[] {
  var result: any[] = [];

  for (var value of values) {
    if (Array.isArray(value)) {
      result.push(...flattenValues(value));
    } else {
      result.push(value);
    }
  }

  return result;
}

function createBaseFunctions() {
  return {
    //---------- Custom functions ----------//
    print: function (...values: any) {
      console.log(...values);
    },

    NUMBER: (value: any) => {
      if (typeof value === "undefined") {
        throw new Error(
          "function NUMBER(value) expects 1 argument, but 0 were provided",
        );
      }

      return Number(value);
    },

    DECIMAL_PLACES: (value: any) => {
      if (typeof value === "undefined") {
        throw new Error(
          "function DECIMAL_PLACES(value) expects 1 argument, but 0 were provided",
        );
      }

      if (Number.isNaN(Number(value))) {
        throw new Error(
          `function DECIMAL_PLACES(value) expects a numeric argument, but received: ${value}`,
        );
      }

      const decimalPart = String(value).split(".")[1];

      return decimalPart ? decimalPart.length : 0;
    },

    SIG: (value: number, figs = 2) => {
      if (typeof value === "undefined") {
        throw new Error(
          "function SIGN(value) expects 1 argument, but 0 were provided",
        );
      }

      if (Number.isNaN(Number(value))) {
        throw new Error(
          `function SIGN(value) expects a numeric argument, but received: ${value}`,
        );
      }

      if (Number.isNaN(Number(figs))) {
        throw new Error(
          `function SIGN(value, figs) expects a numeric argument for figs, but received: ${figs}`,
        );
      }

      function formatToSigFigs(num: number, sigFigs = 2) {
        if (num === 0) return "0";

        const sign = num < 0 ? "-" : "";
        num = Math.abs(num);

        const exponent = Math.floor(Math.log10(num));

        // --- Small numbers (< 0.1): decimal format, round UP, preserve trailing zeros ---
        if (num < 0.1) {
          const scale = Math.pow(10, sigFigs - Math.floor(Math.log10(num)) - 1);
          const rounded = Math.ceil(num * scale) / scale;
          let str = rounded.toPrecision(sigFigs);

          // Add trailing zeros if needed
          const [intPart, decPart = ""] = str.split(".");
          const digits = intPart.replace(/^0+/, "") + decPart;
          let zerosNeeded = sigFigs - digits.length;
          if (zerosNeeded > 0) {
            str += decPart ? "" : ".";
            str += "0".repeat(zerosNeeded);
          }

          return sign + str;
        }

        // --- Numbers < 300: round UP, show trailing .0 if needed ---
        if (num < 300) {
          const scale = Math.pow(10, exponent - sigFigs + 1);
          const rounded = Math.ceil(num / scale) * scale;
          let str = rounded.toPrecision(sigFigs);

          // Add ".0" if it's an integer but only 1 sig fig
          if (!str.includes(".") && sigFigs > 1) {
            const digitCount = str.replace(/^0+/, "").length;
            if (digitCount < sigFigs) {
              str += ".0".substring(0, sigFigs - digitCount + 1);
            }
          }

          return sign + str;
        }

        // --- Engineering notation for numbers >= 300 ---
        let engExp = Math.floor(exponent / 3) * 3;
        let mantissa = num / Math.pow(10, engExp);

        // Round up mantissa to desired sig figs
        const mantExp = Math.floor(Math.log10(mantissa));
        const scale = Math.pow(10, mantExp - sigFigs + 1);
        mantissa = Math.ceil(mantissa / scale) * scale;

        // Shift mantissa down if it's too big
        while (mantissa >= 100) {
          mantissa /= 1000;
          engExp += 3;
        }

        let mantStr = mantissa.toPrecision(sigFigs);

        // Add trailing .0 if necessary
        if (!mantStr.includes(".") && sigFigs > 1) {
          const digits = mantStr.replace(/^0+/, "").length;
          if (digits < sigFigs) {
            mantStr += ".0".substring(0, sigFigs - digits + 1);
          }
        }

        return sign + mantStr + "E+" + engExp;
      }

      console.log(
        "SIG:",
        value,
        "figs:",
        figs,
        "formatted:",
        formatToSigFigs(value, figs),
      );

      return formatToSigFigs(value, figs);
    },

    //---------- Excel or Math functions ----------//
    POWER: function (base: number, exponent: number) {
      if (typeof base === "undefined" || typeof exponent === "undefined") {
        throw new Error(
          "function POWER(base, exponent) expects 2 arguments, but less were provided",
        );
      }

      if (Number.isNaN(Number(base)) || Number.isNaN(Number(exponent))) {
        throw new Error(
          `function POWER(base, exponent) expects numeric arguments, but received: ${base}, ${exponent}`,
        );
      }

      return Math.pow(base, exponent);
    },

    EXP: function (value: number) {
      if (typeof value === "undefined") {
        throw new Error(
          "function EXP(value) expects 1 argument, but 0 were provided",
        );
      }

      if (Number.isNaN(Number(value))) {
        throw new Error(
          `function EXP(value) expects a numeric argument, but received: ${value}`,
        );
      }
      return Math.exp(value);
    },

    SUM: function (...values: any) {
      if (typeof values === "undefined") {
        throw new Error(
          "function SUM(array) expects at least 1 argument, but 0 were provided",
        );
      }

      var items = flattenValues(values);

      return items.reduce(function (total, value) {
        return total + Number(value || 0);
      }, 0);
    },

    AVERAGE: function (...values: any) {
      if (typeof values === "undefined") {
        throw new Error(
          "function AVERAGE(array) expects at least 1 argument, but 0 were provided",
        );
      }

      const items = flattenValues(values);

      const total = items.reduce((total, value) => {
        return total + Number(value || 0);
      }, 0);

      return total / items.length;
    },

    STDEV: (...values: any) => {
      const items = flattenValues(values);

      if (items.length < 2) {
        throw new Error("STDEV(array) requires at least 2 values");
      }

      function calculateStandardDeviation(arr: any[]) {
        if (arr.length === 0) {
          return 0; // Or handle error as appropriate
        }

        // Calculate the mean
        const mean =
          arr.reduce((sum, value) => sum + Number(value), 0) / arr.length;

        // Calculate the sum of squared differences from the mean
        const sumOfSquaredDifferences = arr.reduce(
          (sum, value) => sum + Math.pow(Number(value) - mean, 2),
          0,
        );

        // Calculate the variance (sample variance)
        const variance = sumOfSquaredDifferences / (arr.length - 1);

        // Calculate the standard deviation
        return Math.sqrt(variance);
      }

      return calculateStandardDeviation(items);
    },

    SUMSQ: function (...values: any) {
      if (typeof values === "undefined") {
        throw new Error(
          "function SUMSQ(array) expects at least 1 argument, but 0 were provided",
        );
      }

      var items = flattenValues(values);

      return items.reduce(function (total, value) {
        return total + Math.pow(Number(value || 0), 2);
      }, 0);
    },
    TREND: function (
      knownYValues: number[],
      knownXValues: number[],
      newXValue: number,
    ) {
      if (
        typeof knownYValues === "undefined" ||
        typeof knownXValues === "undefined" ||
        typeof newXValue === "undefined"
      ) {
        throw new Error(
          "function TREND(knownYValues, knownXValues, newXValue) expects 3 arguments, but less were provided",
        );
      }

      if (!Array.isArray(knownYValues) || !Array.isArray(knownXValues)) {
        throw new Error(
          "function TREND(knownYValues, knownXValues, newXValue) expects knownYValues and knownXValues to be arrays",
        );
      }

      if (Number.isNaN(Number(newXValue))) {
        throw new Error(
          `function TREND(knownYValues, knownXValues, newXValue) expects newXValue to be a number, but received: ${newXValue}`,
        );
      }

      const trend = (knownY: number[], knownX: number[], newX: number) => {
        var n = knownX.length;

        var sumX = knownX.reduce((a, b) => a + b, 0);
        var sumY = knownY.reduce((a, b) => a + b, 0);

        var sumXY = 0;
        var sumX2 = 0;

        for (var i = 0; i < n; i++) {
          sumXY += knownX[i] * knownY[i];
          sumX2 += knownX[i] * knownX[i];
        }

        var slope = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);

        var intercept = (sumY - slope * sumX) / n;

        return intercept + slope * newX;
      };

      return trend(knownYValues, knownXValues, newXValue);
    },

    RAND: function () {
      return Math.random();
    },

    MIN: function (...values: any) {
      if (typeof values === "undefined") {
        throw new Error(
          "function MIN(array) expects at least 1 argument, but 0 were provided",
        );
      }

      var items = flattenValues(values);

      return Math.min(...items.map((value) => Number(value || 0)));
    },

    MAX: function (...values: any) {
      if (typeof values === "undefined") {
        throw new Error(
          "function MAX(array) expects at least 1 argument, but 0 were provided",
        );
      }

      var items = flattenValues(values);

      return Math.max(...items.map((value) => Number(value || 0)));
    },

    ABS: function (value: number) {
      if (typeof value === "undefined") {
        throw new Error(
          "function ABS(value) expects 1 argument, but 0 were provided",
        );
      }

      if (Number.isNaN(Number(value))) {
        throw new Error(
          `function ABS(value) expects a numeric argument, but received: ${value}`,
        );
      }

      return Math.abs(value);
    },

    SQRT: function (value: number) {
      if (typeof value === "undefined") {
        throw new Error(
          "function SQRT(value) expects 1 argument, but 0 were provided",
        );
      }

      if (Number.isNaN(Number(value))) {
        throw new Error(
          `function SQRT(value) expects a numeric argument, but received: ${value}`,
        );
      }

      return Math.sqrt(value);
    },

    LOG: function (value: number, base?: string | number) {
      if (typeof value === "undefined") {
        throw new Error(
          "function LOG(value, [base]) expects at least 1 argument, but 0 were provided",
        );
      }

      if (Number.isNaN(Number(value))) {
        throw new Error(
          `function LOG(value, [base]) expects numeric arguments, but received: ${value}, ${base}`,
        );
      }

      if (typeof base === "undefined" || base === null) {
        base = 10;
      }

      if (base === "e") {
        return Math.log(value);
      }

      if (Number.isNaN(Number(base))) {
        throw new Error(
          `function LOG(value, [base]) expects numeric arguments, but received: ${value}, ${base}`,
        );
      }

      return Math.log(value) / Math.log(base as number);
    },

    FIXED: function (value: number, decimals: number) {
      if (typeof value === "undefined" || typeof decimals === "undefined") {
        throw new Error(
          "function FIXED(value, decimals) expects 2 arguments, but less were provided",
        );
      }

      if (Number.isNaN(Number(value)) || Number.isNaN(Number(decimals))) {
        throw new Error(
          `function FIXED(value, decimals) expects numeric arguments, but received: ${value}, ${decimals}`,
        );
      }

      return Number(value).toFixed(decimals);
    },

    ROUND: function (value: number, decimals = 0) {
      if (typeof value === "undefined") {
        throw new Error(
          "function ROUND(value, [decimals = 0]) expects at least 1 argument, but 0 were provided",
        );
      }

      if (Number.isNaN(Number(value)) || Number.isNaN(Number(decimals))) {
        throw new Error(
          `function ROUND(value, [decimals = 0]) expects numeric arguments, but received: ${value}, ${decimals}`,
        );
      }

      const factor = Math.pow(10, decimals);

      return Math.round(value * factor) / factor;
    },
  };
}

export interface FunctionServices {
  /** Return preloaded records or use a synchronous cache, not a Promise. */
  getStandardErrors?: (standardId: any) => Record<string, any>[];
  getUnitById?: (unitId: any) => Record<string, any> | null;
  getUnitByName?: (name: any) => Record<string, any> | null;
  convertUnit?: (
    fromUnitId: any,
    toUnitId: any,
    value: number,
  ) => number | null;
}
export interface FunctionsOptions {
  getEnv?: () => Env;
  services?: FunctionServices;
  output?: (...values: any[]) => void;
}

function required(value: any, name: string, parameter: string) {
  if (value === undefined)
    throw new Error(`${name}() <${parameter}> is required`);
  return value;
}
function numeric(value: any, name: string, parameter = "number"): number {
  required(value, name, parameter);
  const number = Number(value);
  if (!Number.isFinite(number))
    throw new Error(`${name}() <${parameter}> must be a finite number`);
  return number;
}
function array(value: any, name: string): any[] {
  required(value, name, "array");
  if (!Array.isArray(value))
    throw new Error(`${name}() <array> must be an array`);
  return value;
}
function collection(value: any, name: string): Record<string, any> | any[] {
  if (!value || typeof value !== "object")
    throw new Error(`${name}() expects an array or object`);
  return value;
}
function integer(value: any, name: string, parameter: string): number {
  const n = numeric(value, name, parameter);
  if (!Number.isInteger(n))
    throw new Error(`${name}() <${parameter}> must be an integer`);
  return n;
}

/** Zero-based MATCH. Approximate modes expect ascending (1) or descending (-1) input. */
export function matchValue(value: any, data: any[], matchType = 1): number {
  array(data, "MATCH");
  if (![0, 1, -1].includes(matchType))
    throw new Error("MATCH() matchType must be -1, 0 or 1");
  const normalize = (v: any) => (!Number.isNaN(Number(v)) ? Number(v) : v);
  const lookup = normalize(value);
  let found = -1;
  for (let i = 0; i < data.length; i++) {
    const item = normalize(data[i]);
    if (matchType === 0) {
      if (item === lookup) return i;
    } else if (matchType === 1 ? item <= lookup : item >= lookup) {
      found = i;
    }
  }
  return found;
}

function matrix(value: any, name: string): number[][] {
  const rows = array(value, name);
  if (!rows.length || !Array.isArray(rows[0]) || !rows[0].length)
    throw new Error(`${name}() expects a nonempty rectangular matrix`);
  const width = rows[0].length;
  return rows.map((row) => {
    if (!Array.isArray(row) || row.length !== width)
      throw new Error(`${name}() expects a rectangular matrix`);
    return row.map((v) => numeric(v, name));
  });
}
function inverse(value: any): number[][] {
  const a = matrix(value, "MINVERSE");
  const n = a.length;
  if (a[0].length !== n) throw new Error("MINVERSE() expects a square matrix");
  // Partial pivoting avoids division by zero for invertible matrices with a zero diagonal.
  const work = a.map((row, i) => [
    ...row,
    ...Array.from({ length: n }, (_, j) => (i === j ? 1 : 0)),
  ]);
  for (let column = 0; column < n; column++) {
    let pivot = column;
    for (let i = column + 1; i < n; i++)
      if (Math.abs(work[i][column]) > Math.abs(work[pivot][column])) pivot = i;
    if (work[pivot][column] === 0)
      throw new Error("MINVERSE() matrix is singular");
    [work[column], work[pivot]] = [work[pivot], work[column]];
    const divisor = work[column][column];
    for (let j = 0; j < n * 2; j++) work[column][j] /= divisor;
    for (let i = 0; i < n; i++) {
      if (i === column) continue;
      const factor = work[i][column];
      for (let j = 0; j < n * 2; j++) work[i][j] -= factor * work[column][j];
    }
  }
  return work.map((row) => row.slice(n));
}

/** Functions accept evaluated values directly, like the original index.ts. */
export function createFunctions(options: FunctionsOptions = {}) {
  const base = createBaseFunctions();
  function sync<T>(value: T, name: string): T {
    if (value && typeof (value as any).then === "function")
      throw new Error(
        `${name}() requires synchronous/preloaded data; Promise is not supported`,
      );
    return value;
  }
  function envValue(name: string, fallback?: any) {
    const env = options.getEnv?.();
    return env?.has(name) ? env.get(name) : fallback;
  }
  function currentRow(level: any = 0): number {
    const index = integer(level, "GET_CURRENT_ROW_INDEX", "level");
    const env = options.getEnv?.();
    const name = env?.has("CURRENT_ROWS") ? "CURRENT_ROWS" : "CURRENT_ROW";
    const rows = env?.has(name) ? env.get(name) : undefined;
    if (!Array.isArray(rows) || index < 0 || rows[index] === undefined)
      throw new Error(`${name}[${index}] is required`);
    return integer(rows[index], "GET_CURRENT_ROW_INDEX", "row index");
  }
  function standards(id: any): Record<string, any>[] {
    required(id, "FIND_STD_ERROR", "standard_id");
    if (!options.services?.getStandardErrors)
      throw new Error(
        "Standard service is not configured: provide services.getStandardErrors",
      );
    const records = sync(
      options.services.getStandardErrors(id),
      "FIND_STD_ERROR",
    );
    return [...array(records, "FIND_STD_ERROR")].sort(
      (a, b) => Number(a.value) - Number(b.value),
    );
  }
  function normalizeUnit(unit: Record<string, any> | null) {
    if (!unit) return null;
    return {
      ID: unit.ID ?? unit.unit_id,
      SYMBOL: unit.SYMBOL ?? unit.unit_short_name_en,
      NAME: unit.NAME ?? unit.unit_name_en,
    };
  }
  function roundDirected(value: any, digits: any, up: boolean) {
    const n = numeric(value, up ? "ROUNDUP" : "ROUNDDOWN");
    const d = integer(digits, up ? "ROUNDUP" : "ROUNDDOWN", "digits");
    const factor = 10 ** d;
    if (
      !Number.isFinite(factor) ||
      factor === 0 ||
      !Number.isFinite(n * factor)
    )
      throw new Error("Rounding digits are out of range");
    return (
      (up
        ? n >= 0
          ? Math.ceil(n * factor)
          : Math.floor(n * factor)
        : Math.trunc(n * factor)) / factor
    );
  }
  return {
    ...base,
    print: options.output ?? base.print,
    SUCCESS: (value: any = null, message?: any) => ({
      type: "success",
      value,
      message,
    }),
    ERROR: (message: any = "", data: any = null) => ({
      type: "error",
      message,
      data,
    }),
    FIRST: (data: any[]) => {
      const items = array(data, "FIRST");
      return items.length ? items[0] : null;
    },
    LAST: (data: any[], returnIndex = false) => {
      const items = array(data, "LAST");
      return items.length
        ? returnIndex
          ? items.length - 1
          : items[items.length - 1]
        : null;
    },
    COUNT: (data: any[]) => array(data, "COUNT").length,
    SORTING: (data: any[], sortType = "asc") =>
      array(data, "SORTING").sort((a, b) =>
        sortType === "asc" ? Number(a) - Number(b) : Number(b) - Number(a),
      ),
    IS_INFINITY: (value: any) => {
      required(value, "IS_INFINITY", "number");
      const n = Number(value);
      if (Number.isNaN(n))
        throw new Error("IS_INFINITY() <number> must be a number");
      return n === Infinity || n === -Infinity;
    },
    FIND_INDEX: (data: any[], value: any, last = false) => {
      required(value, "FIND_INDEX", "lookup_value");
      const normalize = (v: any) => (!Number.isNaN(Number(v)) ? Number(v) : v);
      const items = array(data, "FIND_INDEX").map(normalize);
      const index = last
        ? items.lastIndexOf(normalize(value))
        : items.indexOf(normalize(value));
      return index < 0 ? null : index;
    },
    MAP: (data: any, mapKey: any, filters?: any[], exclude = false) => {
      required(mapKey, "MAP", "map_key");
      collection(data, "MAP");
      if (filters !== undefined && filters !== null) array(filters, "MAP");
      return Object.keys(data)
        .filter((key) => {
          const index = Number.isNaN(Number(key)) ? key : Number(key);
          return (
            !filters ||
            (exclude === true
              ? !filters.includes(index)
              : filters.includes(index))
          );
        })
        .map((key) => {
          if (!mapKey) return data[key];
          const value = data[key]?.[mapKey];
          return Number.isNaN(Number(value)) ? value : Number(value);
        });
    },
    // Keep the existing variadic/nested-array form as well as SUM(data, key).
    SUM: (...values: any[]) => {
      if (
        values.length === 2 &&
        typeof values[1] === "string" &&
        values[0] &&
        typeof values[0] === "object"
      ) {
        return Object.values(values[0]).reduce<number>(
          (sum, item: any) => sum + Number(item?.[values[1]] ?? 0),
          0,
        );
      }
      if (
        values.length === 1 &&
        values[0] &&
        !Array.isArray(values[0]) &&
        typeof values[0] === "object"
      )
        return 0;
      return base.SUM(...values);
    },
    AVERAGE: (...values: any[]) =>
      flattenValues(values).length ? base.AVERAGE(...values) : 0,
    STDEV: (...values: any[]) => {
      const items = flattenValues(values);
      if (!items.length) return 0;
      if (items.length === 1) return NaN;
      return base.STDEV(...values);
    },
    FIXED: (value: any, digits: any = 2) =>
      base.FIXED(value, integer(digits, "FIXED", "digits")),
    EMPTY: (value: any) =>
      value === undefined ||
      value === null ||
      Number.isNaN(value) ||
      (Array.isArray(value) && value.length === 0) ||
      (typeof value === "string" && value.trim().length === 0),
    STR: (value: any) => String(value),
    NUM: (value: any) => Number(value),
    ROW: (data: any[], manualIndex: any = null, level: any = 0) => {
      array(data, "ROW");
      const index =
        manualIndex === null || manualIndex === false
          ? currentRow(level)
          : integer(manualIndex, "ROW", "row index");
      return data[index];
    },
    GET_CURRENT_ROW_INDEX: (level: any = 0) => currentRow(level),
    MATCH: (value: any, data: any[], matchType = 1) =>
      matchValue(required(value, "MATCH", "lookup_value"), data, matchType),
    INDEX: (data: any[][], row: any, column: any) => {
      array(data, "INDEX");
      const r = integer(row, "INDEX", "row index"),
        c = integer(column, "INDEX", "column index");
      return r < 0 || c < 0 ? null : (data[r]?.[c] ?? null);
    },
    ISNULL: (value: any) => value === null,
    FORMAT_EXPO: (value: any, fractionDigits?: any) =>
      numeric(value, "FORMAT_EXPO").toExponential(
        fractionDigits === undefined
          ? undefined
          : integer(fractionDigits, "FORMAT_EXPO", "fractionDigits"),
      ),
    ROUNDUP: (value: any, digits: any = 0) =>
      roundDirected(value, digits, true),
    ROUNDDOWN: (value: any, digits: any = 0) =>
      roundDirected(value, digits, false),
    INT: (value: any) => Math.floor(numeric(value, "INT")),
    MMULT: (matrixA: any, matrixB: any) => {
      const a = matrix(matrixA, "MMULT"),
        b = matrix(matrixB, "MMULT");
      if (a[0].length !== b.length)
        throw new Error(
          "Matrix dimensions are not compatible for multiplication.",
        );
      return a.map((row) =>
        b[0].map((_, column) =>
          row.reduce((sum, value, k) => sum + value * b[k][column], 0),
        ),
      );
    },
    MINVERSE: (value: any) => inverse(value),
    TINV: (probability: any, degreesOfFreedom: any) => {
      const p = numeric(probability, "TINV", "probability");
      const df = integer(degreesOfFreedom, "TINV", "degrees_of_freedom");
      if (p <= 0 || p > 1 || df < 1)
        throw new Error(
          "TINV() requires 0 < probability <= 1 and degrees_of_freedom >= 1",
        );
      return p === 1 ? 0 : jStat.studentt.inv(1 - p / 2, df);
    },
    RANDBETWEEN: (min: any, max: any) => {
      const low = parseInt(required(min, "RANDBETWEEN", "min"), 10),
        high = parseInt(required(max, "RANDBETWEEN", "max"), 10);
      if (!Number.isFinite(low) || !Number.isFinite(high) || high < low)
        throw new Error(
          "RANDBETWEEN() expects valid integer bounds with min <= max",
        );
      return Math.floor(Math.random() * (high - low + 1)) + low;
    },
    FIND_REF_SETTING: (
      setting: any,
      verticalValue: any,
      horizontalValue?: any,
    ) => {
      required(setting, "FIND_REF_SETTING", "ref_setting");
      const vertical = numeric(
        verticalValue,
        "FIND_REF_SETTING",
        "vertical_value",
      );
      const row = matchValue(vertical, setting.rows);
      const column =
        horizontalValue === undefined
          ? 0
          : matchValue(
              numeric(horizontalValue, "FIND_REF_SETTING", "horizontal_value"),
              setting.columns,
            );
      if (row < 0 || column < 0) return null;
      const found = Number(setting.datas[row]?.[column]);
      if (
        Number(setting.rows[row]) === vertical ||
        row + 1 >= setting.datas.length
      )
        return found;
      return Math.max(found, Number(setting.datas[row + 1][column]));
    },
    FIND_STD_ERROR: (
      standardId: any,
      calibrationPoint?: any,
      compareField: any = "uncertainty",
      returnIndex = false,
    ) => {
      const records = standards(standardId);
      if (!records.length) return null;
      if (calibrationPoint === undefined) return records[0];
      const point = numeric(calibrationPoint, "FIND_STD_ERROR", "lookup_value");
      const values = records.map((item) => Number(item.value));
      if (point < values[0] || point > values[values.length - 1]) return null;
      const row = matchValue(point, values);
      if (!compareField && returnIndex) return row;
      let index = row;
      if (
        values[row] !== point &&
        row + 1 < records.length &&
        Number(records[row + 1][compareField]) >
          Number(records[row][compareField])
      )
        index = row + 1;
      return returnIndex ? index : records[index];
    },
    GET_STD_BY_INDEX: (standardId: any, index: any, column?: any) => {
      const records = standards(standardId);
      required(index, "GET_STD_BY_INDEX", "index");
      if ((index === null || index === false) && column !== undefined)
        return records.map((item) => item[column]);
      const i = integer(index, "GET_STD_BY_INDEX", "index");
      return records[i] ?? null;
    },
    GET_STD_BY_VALUE: (standardId: any, value: any) =>
      standards(standardId).find(
        (record) =>
          Number(record.value) === numeric(value, "GET_STD_BY_VALUE", "value"),
      ) ?? null,
    UNIT: (unitId: any) => {
      required(unitId, "UNIT", "unit_id");
      const units = envValue("_UNIT_", {});
      if (Object.prototype.hasOwnProperty.call(units, unitId))
        return units[unitId];
      if (!options.services?.getUnitById)
        throw new Error(
          "Unit service is not configured: provide services.getUnitById or _UNIT_",
        );
      return normalizeUnit(sync(options.services.getUnitById(unitId), "UNIT"));
    },
    UNIT_ID: (name: any) => {
      required(name, "UNIT_ID", "unit_name");
      if (!options.services?.getUnitByName)
        throw new Error(
          "Unit service is not configured: provide services.getUnitByName",
        );
      const unit = sync(options.services.getUnitByName(name), "UNIT_ID");
      return unit?.unit_id ?? unit?.ID ?? null;
    },
    UNIT_CONVERT: (fromUnitId: any, toUnitId: any, value: any) => {
      required(fromUnitId, "UNIT_CONVERT", "from_unit_id");
      required(toUnitId, "UNIT_CONVERT", "to_unit_id");
      const n = numeric(value, "UNIT_CONVERT", "from_value");
      if (!options.services?.convertUnit)
        throw new Error(
          "Unit service is not configured: provide services.convertUnit",
        );
      return sync(
        options.services.convertUnit(fromUnitId, toUnitId, n),
        "UNIT_CONVERT",
      );
    },
    GOAL_SEEK: (
      fn: (x: number) => number,
      target: any,
      tolerance = 1e-6,
      maxIterations = 100,
    ) => {
      if (typeof fn !== "function")
        throw new Error("GOAL_SEEK() <function> must be a function");
      const goal = numeric(target, "GOAL_SEEK", "target");
      const tol = numeric(tolerance, "GOAL_SEEK", "tolerance");
      const iterations = integer(maxIterations, "GOAL_SEEK", "maxIterations");
      if (tol <= 0 || iterations <= 0)
        throw new Error(
          "GOAL_SEEK() tolerance and maxIterations must be positive",
        );
      const evaluate = (x: number) =>
        numeric(sync(fn(x), "GOAL_SEEK"), "GOAL_SEEK", "callback result") -
        goal;
      const f0 = evaluate(0);
      if (Math.abs(f0) <= tol) return 0;
      let low = 0,
        high = 0,
        found = false,
        step = 1;
      for (let i = 0; i < iterations; i++) {
        if (Math.sign(evaluate(-step)) !== Math.sign(f0)) {
          low = -step;
          high = 0;
          found = true;
          break;
        }
        if (Math.sign(evaluate(step)) !== Math.sign(f0)) {
          low = 0;
          high = step;
          found = true;
          break;
        }
        step *= 2;
      }
      if (!found) throw new Error("Goal Seek: target could not be found");
      let fLow = evaluate(low);
      for (let i = 0; i < iterations; i++) {
        const mid = (low + high) / 2,
          fMid = evaluate(mid);
        if (Math.abs(fMid) <= tol) return mid;
        if (Math.sign(fLow) !== Math.sign(fMid)) high = mid;
        else {
          low = mid;
          fLow = fMid;
        }
      }
      throw new Error("Goal Seek: did not converge within maxIterations");
    },
  };
}
