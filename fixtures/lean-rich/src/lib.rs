#[derive(Debug, PartialEq, Eq)]
pub struct Point {
    pub x: u64,
    pub y: u64,
}

pub fn point_sum(point: &Point) -> u64 {
    point.x.saturating_add(point.y)
}

#[derive(Debug, PartialEq, Eq)]
pub struct Vec2 {
    pub x: u64,
    pub y: u64,
}

pub fn vector_total(vector: &Vec2) -> u64 {
    vector.x.saturating_add(vector.y)
}

#[derive(Debug, PartialEq, Eq)]
pub enum Shape {
    Circle(u64),
    Rectangle(u64, u64),
    Marker,
}

pub fn circle_area(radius: u64) -> u64 {
    radius.saturating_mul(radius)
}

#[cfg(test)]
mod tests {
    use super::{circle_area, point_sum, vector_total, Point, Shape, Vec2};

    #[test]
    fn point_sum_commutes() {
        let point = Point { x: 7, y: 11 };
        assert_eq!(point_sum(&point), 18);
        assert_eq!(point_sum(&point), point.y + point.x);
    }

    #[test]
    fn vector_total_at_least_x() {
        let vector = Vec2 { x: 2, y: 3 };
        assert!(vector_total(&vector) >= vector.x);
        // exact value: the property alone let `+ -> *` survive mutation testing
        assert_eq!(vector_total(&vector), 5);
    }

    #[test]
    fn vector_extensionality() {
        let left = Vec2 { x: 2, y: 3 };
        let right = Vec2 { x: 2, y: 3 };
        let different = Vec2 { x: 2, y: 4 };
        assert_eq!(left, right);
        assert_eq!(
            left == different,
            left.x == different.x && left.y == different.y
        );
    }

    #[test]
    fn private_add_zero() {
        let value = 9_u64;
        assert_eq!(value.checked_add(0), Some(value));
    }

    #[test]
    fn zero_add_identity() {
        assert_eq!(0_u64.checked_add(8), Some(8));
    }

    #[test]
    fn triple_at_least_input() {
        let value = 5_u64;
        assert!(value + value + value >= value);
    }

    #[test]
    fn circle_area_is_positive() {
        let radius = 4;
        let shape = Shape::Circle(radius);
        assert!(matches!(shape, Shape::Circle(r) if r > 0));
        assert!(circle_area(radius) > 0);
        // exact value: positivity alone let `* -> +`, `* -> /` and `-> 1` survive mutation testing
        assert_eq!(circle_area(radius), 16);
    }
}
