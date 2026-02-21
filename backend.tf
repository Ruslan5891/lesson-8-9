# terraform {
#   backend "s3" {
#     bucket         = "lesson-8-terraform-state-bucket-test"
#     key            = "lesson-8/terraform.tfstate"
#     region         = "eu-central-1"
#     dynamodb_table = "terraform-locks"
#     encrypt        = true
#   }
# }

