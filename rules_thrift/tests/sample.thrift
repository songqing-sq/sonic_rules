// Minimal IDL exercising a const, a struct, and a service so codegen emits the
// *_constants, *_types, and Service.{cpp,h} / -remote / -consts outputs for
// cpp / py / go.
namespace cpp sample
namespace py sample
namespace go sample

const i32 MAX_ITEMS = 100

struct Item {
  1: i32 id,
  2: string name,
}

service ItemService {
  Item getItem(1: i32 id),
  void putItem(1: Item item),
}
