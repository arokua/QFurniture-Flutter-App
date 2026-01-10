\# Detailed Project Documentation for Ecommerce Flutter App

This file contains detailed documentation of all relevant files, classes, functions, and helper dependencies in the repository.

---

## 1. API Service

### File: `lib/api_service.dart`

- **Class:** `ApiService`

  - **Function:** `static String url(int nrResults)`
    - Returns the URL string to fetch random users from the API, e.g., `'http://api.randomuser.me/?results=10'`
    - Used internally by `getUsers`

  - **Function:** `static Future<List<User>> getUsers({int nrUsers = 1})`
    - Asynchronously fetches user data from the remote API.
    - Uses `http.get` with `Uri.parse`.
    - Parses JSON response into list of `User` objects using `User.fromJson`.
    - Parameters:
      - `nrUsers`: number of users to fetch, defaults to 1.
    - Returns list of `User` or empty list on error.

- **Imports:**
  - `package:http/http.dart` as `http` for HTTP calls
  - `dart:convert` for JSON operations
  - `lib/models/user.dart` for user model

---

## 2. Models

### File: `lib/models/user.dart`

- **Class:** `User`
  - Represents a user entity with fields:
    - `gender` (String)
    - `name` (Name)
    - `location` (Location)
    - `email` (String)
    - `login` (Login)
    - `dob` (Dob)
    - `registered` (Registered)
    - `phone` (String)
    - `cell` (String)
    - `id` (Id)
    - `picture` (Picture)
    - `nat` (String)
  - Methods:
    - `factory User.fromJson(Map<String, dynamic> json)` - JSON deserialization
    - `Map<String, dynamic> toJson()` - JSON serialization
  - Uses `json_serializable` package for code generation
  - **Helper files for submodels:**
    - `lib/models/name.dart`
    - `lib/models/location.dart`
    - `lib/models/login.dart`
    - `lib/models/dob.dart`
    - `lib/models/registered.dart`
    - `lib/models/id.dart`
    - `lib/models/picture.dart`

### File: Other model files (e.g. `name.dart`, `location.dart`, etc.)

- Define related sub-objects of `User` like Name, Location, Login, Dob, Registered, Id, Picture
- Each have their own JSON serialization logic using `json_serializable`

---

## 3. Main Pages and Screens

### File: `lib/screens/main/main_page.dart`

- **Class:** `MainPage` (StatefulWidget)
  - State: `_MainPageState`

- **State Class Functions:**
  - `initState()` - initializes tab controllers
  - `build(BuildContext context)` - builds UI with nested scroll views, tabs, product lists, bottom navigation

- **UI Elements & Rendering:**
  - Custom app bar with buttons leading to `NotificationsPage` and `SearchPage`
  - Top timeline header with selectable timeliness updating product lists dynamically
  - `TabBar` with category tabs
  - `TabBarView` showing views:
    - Featured products with `ProductList`
    - `CategoryListPage`
    - `CheckOutPage`
    - `ProfilePage`
  - `CustomBottomBar` as bottom navigation

- **Dependencies:**
  - `CustomBottomBar` (in `lib/screens/main/components/custom_bottom_bar.dart`)
  - `ProductList` (in `lib/screens/main/components/product_list.dart`)
  - `TabView` (in `lib/screens/main/components/tab_view.dart`)
  - Navigation to pages:
    - `NotificationsPage` (`lib/screens/notifications_page.dart`)
    - `SearchPage` (`lib/screens/search_page.dart`)
    - `CategoryListPage` (`lib/screens/category/category_list_page.dart`)
    - `CheckOutPage` (`lib/screens/shop/check_out_page.dart`)
    - `ProfilePage` (`lib/screens/profile_page.dart`)

- **Data:**
  - Local list of `Product` objects with details like name, description, image, price

---

## 4. Components Under `lib/screens/main/components/`

- `custom_bottom_bar.dart`
  - Provides the bottom navigation bar widget
  - Used in `MainPage`

- `product_list.dart`
  - Renders scrollable list of products
  - Takes `List<Product>` as parameter

- `tab_view.dart`
  - Holds tab views for main categories
  - Controlled by tab controller from `MainPage`

- `category_card.dart`, `recommended_list.dart`
  - UI cards for categories and recommended products

---

## 5. Other Significant Pages

- `lib/screens/category/category_list_page.dart`
  - Shows categories of products
  - Uses components in `lib/screens/category/components/`

- `lib/screens/shop/check_out_page.dart`
  - Checkout UI for cart items

- `lib/screens/profile_page.dart`
  - User profile management screen

- `lib/screens/notifications_page.dart`
  - Lists user notifications

- `lib/screens/search_page.dart`
  - Search interface for products

- `lib/screens/product/components/`
  - Contains detailed product components:
    - `shop_product.dart`, `product_card.dart`, `product_display.dart`
    - Bottom sheets like `shop_bottomSheet.dart`, `rating_bottomSheet.dart`
    - Product options UI

---

## 6. Supporting and Utility Files

- `lib/main.dart`
  - Entry point of the app
  - Bootstraps `MainPage` or initial screen

- `lib/app_properties.dart`
  - Defines color themes, styles, constants used app-wide

- `lib/custom_background.dart`
  - Custom paint classes for backgrounds

---

## 7. Pubspec.yaml

- Lists dependencies including:
  - `http`: HTTP package for network calls
  - `json_serializable`, `json_annotation`: for code generation of JSON models
  - UI libraries like `flutter_svg`, `card_swiper`, `flutter_staggered_grid_view`
  - WooCommerce API SDK: `woocommerce_flutter_api`

---

# Summary

This detailed documentation maps clearly which files define what classes and functions, the inter-dependencies between UI screens and components, and helper files for models and utilities.

Let me know if you want me to expand on any particular file(s) or generate markdown sections for additional layers/components.
