import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models/product.dart';
import 'models/user.dart';


class ApiService {
  static String url(int nrResults) {
    return 'http://api.randomuser.me/?results=$nrResults';
  }

  static Future<List<User>> getUsers({int nrUsers = 1}) async {
    try {
      final response = await http.get(
          //TODO flutter 2 migration
        Uri.parse(url(nrUsers)),
        headers: {"Content-Type": "application/json"},
      );

      if (response.statusCode == 200) {
        Map data = json.decode(response.body);
        Iterable list = data["results"];
        List<User> users = list.map((l) => User.fromJson(l)).toList();
        return users;
      } else {
        print(response.body);
        return [];
      }
    } catch (e) {
      print(e);
      return [];
    }
  }

  static Future<List<Product>> getProducts({int page = 1, int perPage = 20}) async {
    try {
      final response = await http.get(
        Uri.parse(productsUrl(page: page, perPage: perPage)),
        headers: {"Content-Type": "application/json"},
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is List) {
          return data
              .map((item) => Product.fromApiJson(item as Map<String, dynamic>))
              .toList();
        }
      } else {
        print(response.body);
      }
      return [];
    } catch (e) {
      print(e);
      return [];
    }
  }
  static String productsUrl({int page = 1, int perPage = 20}) =>
  'https://qfurniture.com.au/wp-json/wc/store/v1/products?page=$page&per_page=$perPage';

}

