/** Sequential array callbacks for the interpreter's automatic-await mode. */
export const asyncArrayMethods = new Set([
  'map', 'filter', 'forEach', 'some', 'every', 'find', 'findIndex', 'reduce', 'reduceRight', 'sort',
]);

export async function callAsyncArrayMethod(
  list: any[], name: string, args: any[],
  call: (fn: any, args: any[], receiver?: any) => Promise<any>,
): Promise<any> {
  const callback = args[0];
  if (typeof callback !== 'function') throw new Error('Callback is not a function');
  if (name === 'sort') {
    const values = list.filter(value => value !== undefined);
    const undefinedCount = list.filter(value => value === undefined).length;
    // Stable insertion sort allows each comparator to suspend.
    for (let i = 1; i < values.length; i++) {
      const value = values[i];
      let j = i;
      while (j > 0 && Number(await call(callback, [values[j - 1], value])) > 0) {
        values[j] = values[j - 1]; j--;
      }
      values[j] = value;
    }
    const length = list.length;
    for (let i = 0; i < length; i++) delete list[i];
    for (let i = 0; i < values.length; i++) list[i] = values[i];
    for (let i = 0; i < undefinedCount; i++) list[values.length + i] = undefined;
    return list;
  }
  const length = list.length;
  const result: any[] = name === 'map' ? new Array(length) : [];
  const reduce = name === 'reduce' || name === 'reduceRight';
  const step = name === 'reduceRight' ? -1 : 1;
  let index = step > 0 ? 0 : length - 1;
  const inRange = () => index >= 0 && index < length;
  let accumulator = args[1];
  if (reduce && args.length < 2) {
    while (inRange() && !(index in list)) index += step;
    if (!inRange()) throw new Error('Reduce of empty array with no initial value');
    accumulator = list[index]; index += step;
  }
  for (; inRange(); index += step) {
    if (!(index in list) && name !== 'find' && name !== 'findIndex') continue;
    const value = list[index];
    const answer = await call(callback,
      reduce ? [accumulator, value, index, list] : [value, index, list],
      reduce ? undefined : args[1]);
    switch (name) {
      case 'map': result[index] = answer; break;
      case 'filter': if (answer) result.push(value); break;
      case 'reduce': case 'reduceRight': accumulator = answer; break;
      case 'find': if (answer) return value; break;
      case 'findIndex': if (answer) return index; break;
      case 'some': if (answer) return true; break;
      case 'every': if (!answer) return false; break;
    }
  }
  switch (name) {
    case 'map': case 'filter': return result;
    case 'reduce': case 'reduceRight': return accumulator;
    case 'findIndex': return -1;
    case 'some': return false;
    case 'every': return true;
    default: return undefined;
  }
}
