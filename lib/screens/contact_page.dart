import 'package:ecommerce_int2/app_properties.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ContactPage extends StatelessWidget {
  static const String reviewUrl =
      'https://g.page/r/CWFh7FllOq6wEAI/review';
  static const String faqUrl =
      'https://www.qfurniture.com.au/frequently-asked-questions-2';
  static const String address =
      'Unit 3, 243A Sunshine Rd Tottenham, VIC 3012 Australia';
  static const String email = 'customercare@qfurniture.com.au';
  static const String phone = '+61422015799';

  static const String logoAsset = 'assets/qfurniture_logo.png';
  static const String qrAsset = 'assets/qfurniture_qr.png';

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw 'Could not launch $url';
    }
  }

  Future<void> _openMap() async {
    final query = Uri.encodeComponent(address);
    final url = 'https://www.google.com/maps/search/?api=1&query=$query';
    await _openUrl(url);
  }

  Future<void> _openEmail() async {
    final uri = Uri(
      scheme: 'mailto',
      path: email,
      query: 'subject=QFurniture%20Support',
    );
    if (!await launchUrl(uri)) {
      throw 'Could not launch email';
    }
  }

  Future<void> _openPhone() async {
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await launchUrl(uri)) {
      throw 'Could not launch phone';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xffF9F9F9),
      appBar: AppBar(
        iconTheme: IconThemeData(color: darkGrey),
        backgroundColor: Colors.transparent,
        elevation: 0.0,
        title: Text(
          'Contact',
          style: TextStyle(color: darkGrey),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: <Widget>[
            Center(
              child: Column(
                children: <Widget>[
                  Image.asset(
                    logoAsset,
                    height: 80,
                    fit: BoxFit.contain,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Home Relax Enjoy',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: darkGrey,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  )
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Warehouse',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: darkGrey,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(address),
                  SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: _openMap,
                    child: Text('Open in Google Maps'),
                  ),
                ],
              ),
            ),
            SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  )
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Contact Us',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: darkGrey,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text('Email: $email'),
                  Text('Tel: 0422 015 799'),
                  SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _openEmail,
                          child: Text('Email'),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _openPhone,
                          child: Text('Call'),
                        ),
                      ),
                    ],
                  )
                ],
              ),
            ),
            SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  )
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Sustainability Focus',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: darkGrey,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text('Plantation wood types:'),
                  SizedBox(height: 4),
                  Text('• Acacia'),
                  Text('• Rubberwood'),
                  Text('• Eucalyptus'),
                  Text('• Douglas Fir'),
                ],
              ),
            ),
            SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  )
                ],
              ),
              child: Column(
                children: <Widget>[
                  Image.asset(
                    qrAsset,
                    height: 140,
                    fit: BoxFit.contain,
                  ),
                  SizedBox(height: 12),
                  TextButton(
                    onPressed: () => _openUrl(faqUrl),
                    child: Text('View FAQ'),
                  ),
                  TextButton(
                    onPressed: () => _openUrl(reviewUrl),
                    child: Text('Leave a Review'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
