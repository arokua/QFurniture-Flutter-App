# QFurniture Mobile App Renovation Plan

## Overview
Transform the existing Flutter ecommerce template into a user-friendly furniture buying app for QFurniture.com.au, with full WordPress/WooCommerce integration for authentication, products, and purchases.

---

## Phase 1: WordPress Authentication Integration

### 1.1 Setup WordPress JWT Authentication
**Goal:** Enable seamless login/registration between web and app

**Tasks:**
- [ ] Install and configure JWT Authentication plugin on WordPress backend
  - Plugin: "JWT Authentication for WP REST API" or "Application Passwords"
  - Generate secret keys for token signing
  - Configure CORS headers for mobile app access

**API Endpoints to Implement:**
```
POST /wp-json/jwt-auth/v1/token          - Login
POST /wp-json/wp/v2/users/register       - Registration  
POST /wp-json/jwt-auth/v1/token/validate - Validate token
POST /wp-json/wp/v2/users/me              - Get user profile
PUT  /wp-json/wp/v2/users/me              - Update user profile
POST /wp-json/bdpwr/v1/reset-password     - Password reset
```

### 1.2 Create Authentication Service
**File:** `lib/services/auth_service.dart`

**Features:**
- Login with email/username + password
- Registration with email, password, first name, last name
- Token storage using `shared_preferences` or `flutter_secure_storage`
- Token refresh mechanism
- Logout functionality
- User session management

**Dependencies to Add:**
```yaml
shared_preferences: ^2.2.0
flutter_secure_storage: ^9.0.0
```

### 1.3 Update Auth Screens
**Files to Modify:**
- `lib/screens/auth/welcome_back_page.dart` - Connect to real login API
- `lib/screens/auth/register_page.dart` - Connect to real registration API
- `lib/screens/auth/forgot_password_page.dart` - Connect to password reset API

**Changes:**
- Replace placeholder navigation with actual API calls
- Add loading states during authentication
- Add error handling and user feedback
- Store JWT token after successful login
- Navigate to MainPage only after successful authentication

### 1.4 Create User Model
**File:** `lib/models/user.dart` (update existing)

**Fields:**
- id, email, username, firstName, lastName
- phone, address (billing/shipping)
- avatar URL
- WooCommerce customer ID

---

## Phase 2: Product Data & Categories

### 2.1 Update Category Structure
**Goal:** Organize products by QFurniture's 4 main categories

**Categories:**
1. **Outdoor Furniture** - Patio sets, outdoor dining, garden furniture
2. **Children Furniture** - Kids' tables, chairs, storage, beds
3. **Indoor Dining** - Dining sets, tables, chairs, buffets
4. **Homewares** - Coconut bowls, candle holders, kitchenware, decor

**Files to Modify:**
- `lib/screens/main/main_page.dart` - Update tabs to match categories
- `lib/screens/category/category_list_page.dart` - Filter by category
- `lib/models/product.dart` - Enhance category handling

### 2.2 Enhance Product Model
**File:** `lib/models/product.dart`

**Additional Fields:**
- `stockStatus` (in stock, out of stock, on backorder)
- `stockQuantity` (integer)
- `variations` (for variable products - sizes, colors, etc.)
- `relatedProducts` (array of product IDs)
- `reviews` (ratings and reviews)
- `specifications` (dimensions, weight, material, age group)
- `careInstructions` (for furniture care)

**Update Price Parsing:**
- Already fixed (divide by 100 for cents to dollars)
- Add currency formatting (AUD $)

### 2.3 Update API Service
**File:** `lib/api_service.dart`

**New Methods:**
```dart
// Categories
static Future<List<Category>> getCategories()
static Future<List<Product>> getProductsByCategory(String categorySlug, {int page, int perPage})

// Products
static Future<Product> getProduct(int productId)
static Future<List<Product>> searchProducts(String query)
static Future<List<Product>> getRelatedProducts(int productId)

// Cart (WooCommerce)
static Future<Cart> getCart(String token)
static Future<Cart> addToCart(String token, int productId, {int quantity, Map variations})
static Future<Cart> updateCartItem(String token, String cartItemKey, int quantity)
static Future<void> removeFromCart(String token, String cartItemKey)
static Future<void> clearCart(String token)

// Orders
static Future<Order> createOrder(String token, OrderData orderData)
static Future<List<Order>> getOrders(String token)
static Future<Order> getOrder(String token, int orderId)
```

**Base URL Configuration:**
```dart
static const String baseUrl = 'https://qfurniture.com.au';
static const String apiBase = '$baseUrl/wp-json';
static const String wcApiBase = '$apiBase/wc/store/v1'; // Public API
static const String wcApiPrivate = '$apiBase/wc/v3';   // Authenticated API
```

---

## Phase 3: Shopping Cart & Checkout

### 3.1 Create Cart Service
**File:** `lib/services/cart_service.dart`

**Features:**
- Local cart storage (for guest users)
- Sync with WooCommerce cart (for logged-in users)
- Add/remove/update items
- Calculate totals (subtotal, shipping, tax, total)
- Apply coupons/discounts
- Persist cart across app sessions

### 3.2 Update Checkout Flow
**Files to Modify:**
- `lib/screens/shop/check_out_page.dart`

**Features:**
- Display cart items with images, quantities, prices
- Shipping address form (or select saved address)
- Billing address form
- Shipping method selection
- Payment method selection
- Order summary with breakdown
- Place order button (creates WooCommerce order)

### 3.3 Create Order Model
**File:** `lib/models/order.dart`

**Fields:**
- orderId, orderNumber, status
- dateCreated, dateModified
- lineItems (products with quantities)
- billingAddress, shippingAddress
- paymentMethod, paymentStatus
- shippingMethod, shippingCost
- totals (subtotal, tax, shipping, total)
- customer notes

### 3.4 Order Confirmation & History
**Files to Create:**
- `lib/screens/orders/order_confirmation_page.dart` - Show order details after purchase
- `lib/screens/orders/order_history_page.dart` - List all user orders
- `lib/screens/orders/order_detail_page.dart` - View single order details

---

## Phase 4: UI/UX Redesign for QFurniture

### 4.1 Brand Colors & Theme
**File:** `lib/app_properties.dart` (update)

**QFurniture Color Palette:**
```dart
// Primary colors (extract from website)
const Color primaryBrown = Color(0xff8B6F47);      // Wood/timber color
const Color primaryGreen = Color(0xff4A7C59);       // Natural/eco color
const Color accentGold = Color(0xffD4AF37);        // Accent/highlight
const Color backgroundCream = Color(0xffF5F1E8);    // Light background
const Color textDark = Color(0xff2C2C2C);           // Dark text
const Color textLight = Color(0xff6B6B6B);          // Light text
```

**Update Theme:**
- Replace yellow/orange colors with wood/natural tones
- Update gradients to match brand
- Set appropriate font families (consider Montserrat or similar)

### 4.2 Homepage Redesign
**File:** `lib/screens/main/main_page.dart`

**New Layout:**
- Hero banner showcasing featured furniture
- Category grid (4 main categories with icons/images)
- Featured products section
- "Why QFurniture?" section" (sustainability, quality, etc.)
- Customer testimonials/reviews
- Remove generic "timeline" headers

**Category Cards:**
- Large, image-based cards
- Icons representing each category
- Tap to view category products

### 4.3 Product Display
**Files to Modify:**
- `lib/screens/main/components/product_list.dart`
- `lib/screens/product/product_page.dart`
- `lib/screens/product/view_product_page.dart`

**Improvements:**
- Larger product images (furniture needs good visuals)
- Image gallery with zoom capability
- Key specifications prominently displayed:
  - Dimensions (L x W x H)
  - Material (Plantation Timber)
  - Weight
  - Assembly required (yes/no)
  - Age group (for children's furniture)
- "Add to Cart" button with quantity selector
- Related products section
- Customer reviews section

### 4.4 Navigation
**File:** `lib/screens/main/components/custom_bottom_bar.dart`

**Bottom Navigation Tabs:**
1. **Home** - Main page with categories
2. **Categories** - Browse all categories
3. **Cart** - Shopping cart (with badge count)
4. **Orders** - Order history
5. **Profile** - User account

---

## Phase 5: User Profile & Account Management

### 5.1 Profile Page
**File:** `lib/screens/profile_page.dart` (update)

**Sections:**
- User info (name, email, phone)
- Saved addresses (billing & shipping)
- Order history link
- Account settings
- Logout button

### 5.2 Address Management
**Files:**
- `lib/screens/address/add_address_page.dart` (update)
- `lib/screens/address/address_list_page.dart` (create)

**Features:**
- Add/edit/delete addresses
- Set default billing address
- Set default shipping address
- Address validation (Australian addresses)

### 5.3 Settings
**File:** `lib/screens/settings/settings_page.dart` (update)

**Options:**
- Change password
- Notification preferences
- Language (if multi-language support)
- About QFurniture
- Terms & Conditions
- Privacy Policy

---

## Phase 6: Search & Filtering

### 6.1 Enhanced Search
**File:** `lib/screens/search_page.dart` (update)

**Features:**
- Real-time search with API
- Search by product name, SKU, category
- Search history
- Popular searches
- Filter results by:
  - Category
  - Price range
  - Material
  - In stock only

### 6.2 Category Filtering
**File:** `lib/screens/category/category_list_page.dart` (update)

**Filters:**
- Price range slider
- Material (Plantation Timber, etc.)
- Age group (for children's furniture)
- Assembly required
- Stock status
- Sort by: Price (low-high, high-low), Name, Newest

---

## Phase 7: Additional Features

### 7.1 Wishlist/Favorites
**Files to Create:**
- `lib/services/wishlist_service.dart`
- `lib/screens/wishlist/wishlist_page.dart`

**Features:**
- Add/remove products to wishlist
- Sync with WordPress (if plugin available)
- Share wishlist

### 7.2 Product Reviews
**Files:**
- `lib/screens/product/components/reviews_section.dart` (create)
- `lib/models/review.dart` (create)

**Features:**
- Display product reviews
- Submit reviews (if logged in)
- Rating stars
- Review images

### 7.3 Notifications
**File:** `lib/screens/notifications_page.dart` (update)

**Types:**
- Order status updates
- Shipping notifications
- New product arrivals
- Special offers/promotions

### 7.4 Push Notifications (Optional)
- Order confirmations
- Shipping updates
- Abandoned cart reminders
- Promotional offers

**Dependencies:**
```yaml
firebase_messaging: ^14.0.0
```

---

## Phase 8: Testing & Optimization

### 8.1 Testing Checklist
- [ ] Authentication flow (login, register, logout)
- [ ] Product browsing and search
- [ ] Add to cart functionality
- [ ] Checkout process
- [ ] Order creation and viewing
- [ ] User profile management
- [ ] Address management
- [ ] Error handling (network errors, API errors)
- [ ] Loading states
- [ ] Offline handling (cache products, show cached data)

### 8.2 Performance Optimization
- Image caching and optimization
- Lazy loading for product lists
- Pagination for products
- Cache API responses where appropriate
- Reduce app size

### 8.3 Error Handling
- Network error messages
- API error handling
- Form validation
- User-friendly error messages

---

## Technical Implementation Details

### WordPress API Integration

#### Authentication Headers
```dart
Map<String, String> getAuthHeaders(String? token) {
  final headers = {
    'Content-Type': 'application/json',
  };
  if (token != null) {
    headers['Authorization'] = 'Bearer $token';
  }
  return headers;
}
```

#### Example: Login Request
```dart
static Future<AuthResponse> login(String username, String password) async {
  final response = await http.post(
    Uri.parse('$baseUrl/wp-json/jwt-auth/v1/token'),
    headers: {'Content-Type': 'application/json'},
    body: json.encode({
      'username': username,
      'password': password,
    }),
  );
  
  if (response.statusCode == 200) {
    final data = json.decode(response.body);
    return AuthResponse(
      token: data['token'],
      user: User.fromJson(data['user']),
    );
  } else {
    throw Exception('Login failed: ${response.body}');
  }
}
```

#### Example: Create Order
```dart
static Future<Order> createOrder(String token, OrderData orderData) async {
  final response = await http.post(
    Uri.parse('$baseUrl/wp-json/wc/v3/orders'),
    headers: getAuthHeaders(token),
    body: json.encode(orderData.toJson()),
  );
  
  if (response.statusCode == 201) {
    return Order.fromJson(json.decode(response.body));
  } else {
    throw Exception('Order creation failed: ${response.body}');
  }
}
```

### State Management
**Recommendation:** Use Provider or Riverpod for state management

**Key State Providers:**
- `AuthProvider` - User authentication state
- `CartProvider` - Shopping cart state
- `ProductProvider` - Product data caching
- `OrderProvider` - Order history

### Dependencies to Add
```yaml
dependencies:
  # Existing...
  shared_preferences: ^2.2.0
  flutter_secure_storage: ^9.0.0
  provider: ^6.0.0  # or riverpod: ^2.0.0
  cached_network_image: ^3.3.0
  image_picker: ^1.0.0
  url_launcher: ^6.2.6  # Already added
  intl: ^0.18.0  # Already added for currency formatting
```

---

## Implementation Priority

### High Priority (MVP)
1. ✅ Fix registration loop (DONE)
2. ✅ Fix price parsing (DONE)
3. WordPress authentication integration
4. Product data fetching from WordPress
5. Basic cart functionality
6. Checkout and order creation
7. UI theme update (colors, branding)

### Medium Priority
8. Category filtering and organization
9. User profile and address management
10. Order history
11. Search functionality
12. Product detail improvements

### Low Priority (Nice to Have)
13. Wishlist
14. Product reviews
15. Push notifications
16. Advanced filtering
17. Social sharing

---

## Estimated Timeline

- **Phase 1 (Auth):** 3-5 days
- **Phase 2 (Products):** 2-3 days
- **Phase 3 (Cart/Checkout):** 4-6 days
- **Phase 4 (UI/UX):** 5-7 days
- **Phase 5 (Profile):** 2-3 days
- **Phase 6 (Search):** 2-3 days
- **Phase 7 (Additional):** 3-5 days
- **Phase 8 (Testing):** 3-5 days

**Total: 24-37 days** (approximately 1-1.5 months for full implementation)

---

## Notes

1. **WordPress Setup Required:**
   - Ensure WooCommerce is installed and configured
   - Install JWT Authentication plugin
   - Configure CORS for mobile app
   - Set up API keys if needed

2. **Price Format:**
   - Backend stores prices as integers (cents)
   - Already fixed: divide by 100 in `_parsePrice()` method
   - Display as AUD currency: `\$${price.toStringAsFixed(2)}`

3. **Account Synchronization:**
   - All user data stored in WordPress
   - App acts as a client to WordPress API
   - No local user database needed
   - JWT tokens provide authentication

4. **Testing:**
   - Test with real WordPress backend
   - Test account creation on web, login on app (and vice versa)
   - Test order creation and viewing
   - Test cart persistence

---

## Next Steps

1. Review and approve this plan
2. Set up WordPress backend (JWT auth, API endpoints)
3. Start with Phase 1 (Authentication)
4. Progress through phases sequentially
5. Regular testing and feedback cycles
