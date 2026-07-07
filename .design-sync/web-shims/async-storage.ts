// Web shim for @react-native-async-storage/async-storage: in-memory map.
// Only reached through the store's language/view-mode hydration; preview
// lifetime persistence is all the synced components need.
const mem = new Map<string, string>();

const AsyncStorage = {
  async getItem(key: string): Promise<string | null> {
    return mem.has(key) ? (mem.get(key) as string) : null;
  },
  async setItem(key: string, value: string): Promise<void> {
    mem.set(key, value);
  },
  async removeItem(key: string): Promise<void> {
    mem.delete(key);
  },
  async clear(): Promise<void> {
    mem.clear();
  },
  async getAllKeys(): Promise<string[]> {
    return [...mem.keys()];
  },
};

export default AsyncStorage;
