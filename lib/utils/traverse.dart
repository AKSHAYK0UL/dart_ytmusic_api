dynamic traverse(dynamic data, List<String> keys) {
  dynamic again(dynamic current, String key, {bool deadEnd = false}) {
    if (current == null) return null;

    if (current is Map) {
      if (current.containsKey(key)) {
        final val = current[key];
        if (deadEnd) return val;
        final res = <dynamic>[];
        if (val != null) res.add(val);
        for (final v in current.values) {
          if (v is Map || v is List) {
            final sub = again(v, key, deadEnd: deadEnd);
            if (sub is List) {
              res.addAll(sub);
            } else if (sub != null) {
              res.add(sub);
            }
          }
        }
        return res.isEmpty ? null : (res.length == 1 ? res[0] : res);
      }

      final res = <dynamic>[];
      for (final v in current.values) {
        if (v is Map || v is List) {
          final sub = again(v, key, deadEnd: deadEnd);
          if (sub is List) {
            res.addAll(sub);
          } else if (sub != null) {
            res.add(sub);
          }
        }
      }
      return res.isEmpty ? null : (res.length == 1 ? res[0] : res);
    }

    if (current is List) {
      final res = <dynamic>[];
      for (final item in current) {
        if (item is Map || item is List) {
          final sub = again(item, key, deadEnd: deadEnd);
          if (sub is List) {
            res.addAll(sub);
          } else if (sub != null) {
            res.add(sub);
          }
        }
      }
      return res.isEmpty ? null : (res.length == 1 ? res[0] : res);
    }

    return null;
  }

  dynamic value = data;
  String? lastKey = keys.isNotEmpty ? keys.last : null;
  for (String key in keys) {
    value = again(value, key, deadEnd: lastKey == key);
  }

  return value;
}

List<dynamic> traverseList(dynamic data, List<String> keys) {
  final val = traverse(data, keys);
  if (val == null) return const [];
  if (val is List) return val.where((x) => x != null).toList();
  return [val];
}

String? traverseString(dynamic data, List<String> keys) {
  final filteredList = traverseList(data, keys);
  if (filteredList.isEmpty) {
    return null;
  }
  final first = filteredList.first;
  if (first == null) return null;
  final str = first.toString().trim();
  if (str.isEmpty || str == 'null') return null;
  return str;
}
