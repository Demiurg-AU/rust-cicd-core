import RichModel.Imported

structure Point where
  x : Nat
  y : Nat
  deriving DecidableEq, Repr

@[ext]
structure Vec2 where
  x : Nat
  y : Nat
  deriving DecidableEq, Repr

inductive Shape where
  | circle : Nat → Shape
  | rectangle : Nat → Nat → Shape
  | marker : Shape
  deriving DecidableEq, Repr

mutual
  inductive Tree where
    | leaf : Nat → Tree
    | branch : Forest → Tree

  inductive Forest where
    | nil : Forest
    | cons : Tree → Forest → Forest
end

theorem point_sum_comm (point : Point) : point.x + point.y = point.y + point.x :=
  Nat.add_comm _ _

namespace Vec2

theorem total_at_least_x (vector : Vec2) : vector.x ≤ vector.x + vector.y :=
  Nat.le_add_right _ _

end Vec2

private theorem private_add_zero (n : Nat) : n + 0 = n :=
  Nat.add_zero n

@[simp]
theorem zero_add_identity (n : Nat) : 0 + n = n :=
  Nat.zero_add n

namespace Shape.circle

theorem area_pos (radius : Nat) (positive : 0 < radius) : 0 < radius * radius :=
  Nat.mul_pos positive positive

end Shape.circle
