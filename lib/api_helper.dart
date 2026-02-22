import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class Api {
  
  // --- 1. INTERNAL TOOLS ---

  // NEW HELPER: Ensures author_uid is present if a user is logged in
  static Map<String, dynamic> _injectAuthData(Map<String, dynamic> data) {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // Only set if the key doesn't exist or is null
      data['author_uid'] ??= user.uid;
      
      // Optional: Also track email if not present
      if (user.email != null) {
        data['email'] ??= user.email;
      }
    }
    return data;
  }

  static String _getPathFromUrl(Uri url) {
    String fullPath = Uri.decodeFull(url.path); 
    if (fullPath.endsWith(':runQuery')) return ":runQuery";

    int docIndex = fullPath.indexOf('/documents/');
    if (docIndex == -1) {
      if (fullPath.endsWith('/documents')) return ""; 
      return "";
    }

    String cleanPath = fullPath.substring(docIndex + 11);
    return cleanPath.endsWith('/') ? cleanPath.substring(0, cleanPath.length - 1) : cleanPath;
  }

  // NEW HELPER: Recursively parses REST API values into native Dart types
  static dynamic _parseValue(Map<String, dynamic> valueMap) {
    if (valueMap.containsKey('stringValue')) return valueMap['stringValue'];
    if (valueMap.containsKey('integerValue')) return int.tryParse(valueMap['integerValue'].toString()) ?? 0;
    if (valueMap.containsKey('doubleValue')) return valueMap['doubleValue'];
    if (valueMap.containsKey('booleanValue')) return valueMap['booleanValue'];
    if (valueMap.containsKey('timestampValue')) return valueMap['timestampValue'];
    if (valueMap.containsKey('nullValue')) return null;

    // Handle Arrays
    if (valueMap.containsKey('arrayValue')) {
      var values = valueMap['arrayValue']['values'] as List<dynamic>? ?? [];
      return values.map((e) => _parseValue(Map<String, dynamic>.from(e))).toList();
    }

    // Handle Nested Maps
    if (valueMap.containsKey('mapValue')) {
      var fields = valueMap['mapValue']['fields'] as Map<String, dynamic>? ?? {};
      Map<String, dynamic> parsedMap = {};
      fields.forEach((k, v) {
        parsedMap[k] = _parseValue(Map<String, dynamic>.from(v));
      });
      return parsedMap;
    }

    return null;
  }

  // UPDATED: Now uses the recursive helper above
  static Map<String, dynamic> _simplifyRestBody(String jsonBody) {
    if (jsonBody.isEmpty) return {};
    try {
      final Map<String, dynamic> raw = jsonDecode(jsonBody);
      if (!raw.containsKey('fields')) return raw;
      
      final Map<String, dynamic> fields = raw['fields'];
      final Map<String, dynamic> cleanData = {};

      fields.forEach((key, valueMap) {
        if (valueMap is Map) {
          cleanData[key] = _parseValue(Map<String, dynamic>.from(valueMap));
        }
      });
      
      return cleanData;
    } catch (e) {
      print("Error parsing body: $e");
      return {};
    }
  }

  // NEW HELPER: Recursively encodes native Dart types back into REST API format
  static dynamic _encodeValue(dynamic value) {
    if (value is String) return {'stringValue': value};
    if (value is int) return {'integerValue': value.toString()};
    if (value is double) return {'doubleValue': value};
    if (value is bool) return {'booleanValue': value};
    if (value is Timestamp) return {'timestampValue': value.toDate().toUtc().toIso8601String()};
    if (value == null) return {'nullValue': 'NULL_VALUE'};

    // Handle Arrays (Lists)
    if (value is List) {
      return {
        'arrayValue': {
          'values': value.map((e) => _encodeValue(e)).toList()
        }
      };
    }

    // Handle Nested Maps
    if (value is Map) {
      Map<String, dynamic> fields = {};
      value.forEach((k, v) {
        fields[k.toString()] = _encodeValue(v);
      });
      return {
        'mapValue': {
          'fields': fields
        }
      };
    }

    return {};
  }

  // UPDATED: Now uses the recursive helper above to catch all your arrays!
  static Map<String, dynamic> _encodeToRest(Map<String, dynamic> data) {
    Map<String, dynamic> fields = {};
    data.forEach((key, value) {
      fields[key] = _encodeValue(value);
    });
    return fields;
  }

  // --- 2. PUBLIC METHODS ---

  static Future<http.Response> get(Uri url) async {
  final user = FirebaseAuth.instance.currentUser;
  
  // Define who the admin is
  bool isAdmin = user?.email == "20981@students.isb.ac.th";

  try {
    String path = _getPathFromUrl(url);
    if (path == "") return http.Response('{"documents": []}', 200);

    bool isCollection = path.split('/').length % 2 != 0;

    if (isCollection) {
      Query query = FirebaseFirestore.instance.collection(path);
      
      // LOGIC CHANGE: 
      // Only apply the filter if the user is NOT the admin.
      if (path != 'users' && user != null && !isAdmin) {
        query = query.where('author_uid', isEqualTo: user.uid);
      }

        QuerySnapshot snapshot = await query.get();
        List<Map<String, dynamic>> documents = snapshot.docs.map((doc) {
          return {
            "name": "projects/mock/databases/(default)/documents/$path/${doc.id}",
            "fields": _encodeToRest(doc.data() as Map<String, dynamic>)
          };
        }).toList();

        return http.Response(jsonEncode({"documents": documents}), 200);
      } else {
        DocumentSnapshot doc = await FirebaseFirestore.instance.doc(path).get();
        if (!doc.exists) return http.Response('{}', 404);
        return http.Response(jsonEncode({
          "name": "projects/mock/databases/(default)/documents/$path/${doc.id}",
          "fields": _encodeToRest(doc.data() as Map<String, dynamic>)
        }), 200);
      }
    } catch (e) {
      return http.Response('{"documents": []}', 200); 
    }
  }

  static Future<http.Response> post(Uri url, {required String body}) async {
    final user = FirebaseAuth.instance.currentUser;
    try {
      String path = _getPathFromUrl(url);

      if (path == ":runQuery") {
        Map<String, dynamic> queryBody = jsonDecode(body);
        String collectionId = queryBody['structuredQuery']['from'][0]['collectionId'] ?? "";
        if (collectionId.isEmpty) return http.Response('[]', 200);

        Query query = FirebaseFirestore.instance.collection(collectionId);
        if (user != null) query = query.where('author_uid', isEqualTo: user.uid);

        QuerySnapshot snapshot = await query.get();
        List<Map<String, dynamic>> results = snapshot.docs.map((doc) {
          return {
            "document": {
              "name": "projects/mock/databases/(default)/documents/$collectionId/${doc.id}",
              "fields": _encodeToRest(doc.data() as Map<String, dynamic>),
            },
            "readTime": DateTime.now().toIso8601String(),
          };
        }).toList();
        return http.Response(jsonEncode(results), 200);
      }

      // --- CREATE LOGIC ---
      Map<String, dynamic> data = _simplifyRestBody(body);
      data = _injectAuthData(data); // <--- INJECTED HERE

      if (!data.containsKey('timestamp')) {
        data['timestamp'] = FieldValue.serverTimestamp();
      }

      DocumentReference ref = await FirebaseFirestore.instance.collection(path).add(data);
      return http.Response('{"name": "${ref.path}"}', 200);
    } catch (e) {
      return http.Response('{"error": "$e"}', 500);
    }
  }

  static Future<http.Response> patch(Uri url, {required String body}) async {
    try {
      String path = _getPathFromUrl(url);
      Map<String, dynamic> data = _simplifyRestBody(body);
      
      // data = _injectAuthData(data); // <--- INJECTED HERE

      await FirebaseFirestore.instance.doc(path).set(data, SetOptions(merge: true));
      return http.Response('{}', 200);
    } catch (e) {
      return http.Response('{"error": "$e"}', 500);
    }
  }

  static Future<http.Response> delete(Uri url) async {
    try {
      String path = _getPathFromUrl(url);
      await FirebaseFirestore.instance.doc(path).delete();
      return http.Response('{}', 200);
    } catch (e) {
      return http.Response('{"error": "$e"}', 500);
    }
  }
}