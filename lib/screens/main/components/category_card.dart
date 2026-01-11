import 'package:ecommerce_int2/models/category.dart';
import 'package:flutter/material.dart';

class CategoryCard extends StatelessWidget {
  final Category category;

  const CategoryCard({
    required this.category,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: Card(
        child: ClipRRect(
          borderRadius: BorderRadius.all(Radius.circular(5)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                height: 80,
                width: 90,
                padding: EdgeInsets.all(8.0),
                child: Center(
                  child: Text(
                    category.category ?? category.name,
                    textAlign: TextAlign.right,
                  ),
                ),
              ),
              Container(
                height: 80,
                width: 90,
                decoration: BoxDecoration(
                    gradient: RadialGradient(
                        colors: [
                          category.begin ?? Color(0xffFCE183),
                          category.end ?? Color(0xffF68D7F)
                        ],
                        center: Alignment(0, 0),
                        radius: 0.8,
                        focal: Alignment(0, 0),
                        focalRadius: 0.1)),
                padding: EdgeInsets.all(8.0),
                child: Center(
                  child: category.image != null && category.image!.startsWith('assets/')
                      ? Image.asset(category.image!)
                      : category.image != null
                          ? Image.network(category.image!, errorBuilder: (context, error, stackTrace) => Icon(Icons.image_not_supported))
                          : Icon(Icons.category),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}
