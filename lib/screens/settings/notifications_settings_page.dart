import 'dart:io';

import 'package:ecommerce_int2/app_properties.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NotificationSettingsPage extends StatefulWidget {
  @override
  _NotificationSettingsPageState createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  bool myOrders = true;
  bool reminders = true;
  bool newOffers = true;
  bool feedbackReviews = true;
  bool updates = true;

  Widget platformSwitch(bool val, ValueChanged<bool> onChanged) {
    if (Platform.isIOS) {
      return CupertinoSwitch(
        onChanged: onChanged,
        value: val,
        activeColor: yellow, // Updated to use activeColor for iOS
      );
    } else {
      return Switch(
        onChanged: onChanged,
        value: val,
        activeColor: yellow, // Updated to use activeColor for Android
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        iconTheme: IconThemeData(
          color: Colors.black,
        ),
        backgroundColor: Colors.transparent,
        title: Text(
          'Settings',
          style: TextStyle(color: darkGrey),
        ),
        elevation: 0,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      body: SafeArea(
        bottom: true,
        child: Padding(
          padding: const EdgeInsets.only(top: 24.0, left: 24.0, right: 24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Text(
                  'Notifications',
                  style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 18.0),
                ),
              ),
              Flexible(
                child: ListView(
                  children: <Widget>[
                    ListTile(
                      title: Text('My orders'),
                      trailing: platformSwitch(myOrders, (value) {
                        setState(() {
                          myOrders = value;
                        });
                      }),
                    ),
                    ListTile(
                      title: Text('Reminders'),
                      trailing: platformSwitch(reminders, (value) {
                        setState(() {
                          reminders = value;
                        });
                      }),
                    ),
                    ListTile(
                      title: Text('New Offers'),
                      trailing: platformSwitch(newOffers, (value) {
                        setState(() {
                          newOffers = value;
                        });
                      }),
                    ),
                    ListTile(
                      title: Text('Feedbacks and Reviews'),
                      trailing: platformSwitch(feedbackReviews, (value) {
                        setState(() {
                          feedbackReviews = value;
                        });
                      }),
                    ),
                    ListTile(
                      title: Text('Updates'),
                      trailing: platformSwitch(updates, (value) {
                        setState(() {
                          updates = value;
                        });
                      }),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
