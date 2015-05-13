import 'dart:io';
import 'dart:collection';
import 'dart:convert';

main(List<String> args) async {
  var path = args.first;

  var file = new File(path);

  Map object =
      await JSON.decoder.bind(UTF8.decoder.bind(file.openRead())).single;

  print('Global size: ${object['program']['size']}');

  Map elements = object['elements'];

  var dv = new DumpView.fromJson(elements);

  _groupLibs(dv.libraries);
  _badFunction(dv.functions);
  _countInterceptors(dv.functions);
}

void _countInterceptors(Iterable functions) {
  var funcs = functions.toList();

  funcs.sort((a, b) => -a.interceptorCount.compareTo(b.interceptorCount));

  for (Function func in funcs.take(40)) {
    print([
      func.name,
      func.id,
      func.interceptorCount,
      func.interceptorToSizeRatio
    ]);
  }
}

void _badFunction(Iterable functions) {
  var funcs = functions.toList();

  funcs.sort((a, b) => -a.size.compareTo(b.size));

  var totalSize = funcs.fold(0, (val, func) => val + func.size);

  print('Sum of functions: $totalSize');
  print('Function count: ${funcs.length}');

  var countedSize = 0;
  int i = 0;
  for (; i < funcs.length; i++) {
    Function func = funcs[i];
    countedSize += func.size;

    var pct = func.size / totalSize;

    if (pct > 0.002) {
      print([
        func.name,
        func.id,
        _prettyPct(pct),
        func.size,
        'Interceptors: ${func.interceptorCount}',
        'Try count: ${func.tryCount}'
      ]);
    }

    if (countedSize > (totalSize * .5)) {
      break;
    }
  }

  print([i, countedSize]);
  print(_prettyPct(i / funcs.length));
}

void _groupLibs(Iterable libs) {
  var groups = <String, List<Library>>{};

  for (var lib in libs) {
    var groupName = _classify(lib.name);
    var children = groups.putIfAbsent(groupName, () => <Library>[]);
    children.add(lib);
  }

  var libGroups = groups.keys.map((key) {
    return new LibraryGroup(key, groups[key]);
  }).toList();

  libGroups.sort((LibraryGroup a, LibraryGroup b) {
    return -a.totalSize.compareTo(b.totalSize);
  });

  var globalSize = libGroups.fold(0, (count, next) => count + next.totalSize);

  print('Sum-of-lib size: ${globalSize}');

  for (var group in libGroups) {
    var pct = _prettyPct(group.totalSize / globalSize);

    print('$pct\t$group');
  }
}

final _idRegExp = new RegExp(r'(\w+)\/(\d+)');

typedef Element _Mapper(String elementId);

class DumpView {
  final Map<String, Element> elements;

  Iterable<Function> get functions =>
      elements.values.where((e) => e is Function).map((e) => e);
  Iterable<Library> get libraries =>
      elements.values.where((e) => e is Library).map((e) => e);

  DumpView._(this.elements);

  factory DumpView.fromJson(Map<String, dynamic> elementJson) {
    var elementCache = <String, Element>{};

    _Mapper populateElement;

    populateElement = (String elementId) {
      return elementCache.putIfAbsent(elementId, () {
        var match = _idRegExp.allMatches(elementId).single;
        var kind = match[1];
        var id = match[2];

        var kindMap = elementJson[kind] as Map;

        var elemJson = kindMap.remove(id);

        Map<String, Element> children;

        var childIds = elemJson['children'];
        if (childIds == null) {
          children = const <String, Element>{};
        } else {
          children = <String, Element>{};

          for (var childId in childIds) {
            var child = populateElement(childId);
            children[child.id] = child;
          }
        }

        switch (kind) {
          case 'library':
            return new Library._(elemJson, children);
          case 'class':
            return new Class._(elemJson, children);
          case 'field':
          case 'function':
            return new Function._(elemJson, children);
          case 'typedef':
            assert(children.isEmpty);
            return new Element.fromJson(elemJson);
          default:
            throw 'not expecting kind $kind';
        }
      });
    };

    elementJson.forEach((String kind, Map set) {
      var ids = set.keys.toList();
      for (var id in ids) {
        var elementJson = set[id];
        populateElement(elementJson['id']);
      }
    });

    return new DumpView._(
        new UnmodifiableMapView<String, Element>(elementCache));
  }
}

class Element {
  final String id, kind, name;

  int get size => 0;

  Map<String, Element> get children => const <String, Element>{};

  final Set<ParentElement> _parents = new Set<ParentElement>();

  Element.fromJson(Map<String, dynamic> json)
      : this._(json['id'], json['kind'], json['name']);

  Element._(this.id, this.kind, this.name) {
    assert(id.isNotEmpty);
    assert(kind.isNotEmpty);
    assert(name != null);
  }

  void _claim(ParentElement parent) {
    _parents.add(parent);
  }

  String get fullName {
    var parentName = '';

    if (_parents.length > 1) {
      parentName = '???.';
    } else if (_parents.isNotEmpty) {
      parentName = _parents.single.fullName;
    }

    return "${parentName}${name}";
  }

  Iterable<Element> get decendants => const <Element>[];

  String toString() => [fullName, size, kind, id].toString();
}

class ParentElement extends Element {
  @override
  final int size;

  @override
  final Map<String, Element> children;

  ParentElement._(Map<String, dynamic> json, this.children)
      : this.size = json['size'],
        super.fromJson(json) {
    for (var child in children.values) {
      child._claim(this);
    }
  }

  @override
  Iterable<Element> get decendants sync* {
    for (var child in children) {
      yield child;
      yield* child.decendants;
    }
  }
}

class Class extends ParentElement {
  Class._(Map<String, dynamic> json, Map<String, Element> children)
      : super._(json, children);
}

class Library extends ParentElement {
  Library._(Map<String, dynamic> json, Map<String, Element> children)
      : super._(json, children);
}

/// Anything with code
class Function extends ParentElement {
  static const kinds = const <String>[
    'function',
    'method',
    'closure',
    'constructor',
    'field'
  ];

  // kinds: function, method, closure, constructor
  final String code;

  Function._(Map<String, dynamic> json, Map<String, Element> children)
      : this.code = json['code'],
        super._(json, children) {
    assert(kinds.contains(this.kind));
  }

  num get interceptorToSizeRatio {
    if (size == 0) {
      return 0;
    }
    return interceptorCount / size;
  }

  int get interceptorCount {
    if (code == null) {
      return 0;
    }

    return 'J.'.allMatches(code).length;
  }

  int get tryCount {
    if (code == null) {
      return 0;
    }

    return 'try{'.allMatches(code).length;
  }
}

class LibraryGroup {
  final String groupName;
  final List<Library> libraries;

  LibraryGroup(this.groupName, Iterable<Library> libraries)
      : this.libraries = new List.unmodifiable(libraries);

  int get totalSize =>
      libraries.fold(0, (size, element) => size + element.size);

  String toString() =>
      '$groupName Count: ${libraries.length}, Size: ${totalSize}';
}

String _prettyPct(percent) => (100 * percent).toStringAsFixed(2) + '%';

String _classify(String libName) {
  var sections = libName.split('.');
  return sections.first;
}
