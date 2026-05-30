import { MemoryStorage, StoreItems } from "botbuilder";

// A MemoryStorage that ignores eTag conflicts on write.
//
// The default MemoryStorage throws when two concurrent writers for the same
// key have stale eTags. For our FAQ bot, the bot framework can dispatch
// several activities for one conversation in parallel (conversationUpdate,
// typing, message) and they all touch the same conversation state. The
// concurrent writes race, the loser blows up, and our onTurnError sends a
// spurious "something went wrong" reply on top of the real answer.
//
// We trade strict consistency for availability: last-write-wins.
export class LenientMemoryStorage extends MemoryStorage {
    async write(changes: StoreItems): Promise<void> {
        try {
            await super.write(changes);
        } catch (err) {
            const msg = (err as Error)?.message ?? "";
            if (msg.includes("eTag conflict")) {
                // Last-write-wins: strip eTags and retry once.
                const retried: StoreItems = {};
                for (const [k, v] of Object.entries(changes)) {
                    retried[k] = { ...v, eTag: "*" };
                }
                await super.write(retried);
                return;
            }
            throw err;
        }
    }
}
