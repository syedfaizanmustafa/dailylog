import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Camacho brand + UI colours. Navy stays the primary; the logo greens are
/// used for hero surfaces; the accents each carry one meaning:
/// green = money/approved/delivered, blue = info/sent, amber = pending/SMS,
/// purple = admin, red = failed/destructive.
class AppColors {
  AppColors._();

  // Brand
  static const navy = Color(0xFF2B2D42);
  static const mist = Color(0xFFEDF2F4);
  static const slate = Color(0xFF5C6577);
  static const line = Color(0xFFDCE3E8);
  static const field = Color(0xFFC9D2DB);

  // Logo
  static const forest = Color(0xFF3B5530);
  static const olive = Color(0xFF6E8C46);
  static const sage = Color(0xFF8FA96A);
  static const sageLight = Color(0xFFC7D9B0);
  static const cream = Color(0xFFFAF8F1);

  // Accents: tint / main / text-on-tint
  static const greenTint = Color(0xFFE2F3E8);
  static const green = Color(0xFF2E8B57);
  static const greenText = Color(0xFF1E5C3A);

  static const blueTint = Color(0xFFE3EDFC);
  static const blue = Color(0xFF2F6FDB);
  static const blueText = Color(0xFF1D4E9E);

  static const amberTint = Color(0xFFFDF3DC);
  static const amber = Color(0xFFD98E04);
  static const amberText = Color(0xFF8A5A00);
  static const amberSoft = Color(0xFFFFF9EC);
  static const amberLine = Color(0xFFF5DFA8);

  static const purpleTint = Color(0xFFEFE8FB);
  static const purple = Color(0xFF7C4DCC);
  static const purpleText = Color(0xFF5B34A3);

  static const redTint = Color(0xFFFBE5E2);
  static const red = Color(0xFFC0392B);
  static const redText = Color(0xFF8E2418);
}

/// The Camacho logo mark: the recycling triangle whose arrows are drawn as
/// ruled log-sheet strips (recycling + logging). Vector-traced from the
/// chosen app icon; the same artwork renders the app icons (brand/logo_mark.svg).
class BrandLogo {
  BrandLogo._();

  static const double width = 735.5;
  static const double height = 701.5;

  /// The solid (unruled) parts of the arrows.
  static const _solid =
      'M155.2 663.6C144.7 662.4 136.2 659.2 127.6 653.5C119.8 648.4 115 643.5 109.1 634.7C104.5 627.7 102.2 622.6 99.8 613.2C97.5 604.4 97.5 593.6 99.7 584.5C101.9 575.2 103.8 570.9 110 560.2C112.2 556.6 114.7 552.3 115.7 550.5C116.6 548.7 118.9 544.6 120.7 541.5C122.5 538.4 124.8 534.5 125.7 532.9C126.5 531.3 129 527 131.2 523.4C133.3 519.8 136.2 514.9 137.4 512.5C138.7 510.1 140.8 506.4 142.2 504.2C144.6 500.4 146.9 496.4 150.1 490.6C150.8 489.2 152.3 486.8 153.2 485.3C154.2 483.8 155 482.4 155 482.3C155 482.1 155.7 480.9 156.5 479.6C157.7 477.7 158.4 477.1 159.9 476.6C161.3 476.1 186 476 256.4 476C347.4 476 350.9 476.1 351.7 476.9C352.4 477.8 352.2 478.4 347 488.9C344 495.1 341.5 500.1 341.5 500.2C341.5 500.4 316.6 550.8 312.3 559.5C311.1 562 310 564.7 310 565.5C310 566.5 311.4 569.1 314.6 573.9C317.1 577.6 320.7 583 322.4 585.8C327.9 594.2 331.6 599.9 338.1 609.8C344.6 619.8 348.2 625.2 352.3 631.6C353.6 633.8 357.1 639.2 360.1 643.6C369.1 657.4 372 662.1 372 663.1C372 664 368.3 664 264.4 664C205.2 663.9 156.1 663.8 155.2 663.6ZM87.8 605.4C86.7 603.5 78.8 589.5 76.2 584.8C74.9 582.2 73.3 579.5 72.8 578.5C72.2 577.5 70.1 573.9 68.2 570.2C66.3 566.6 64 562.3 63 560.5C60.6 556.3 58.9 553.2 54.6 545.2C52.7 541.6 49.8 536.2 48.1 533.2C46.5 530.2 44.1 526 43 523.8C41.8 521.5 39.8 517.8 38.4 515.2C37 512.8 34 507.2 31.6 503C29.3 498.8 26.9 494.4 26.2 493.2C25.6 492.1 22.6 486.5 19.4 480.8C16.2 475 12.5 468.2 11.1 465.8C4.8 454.9 1.4 440.9 2.2 429.2C2.6 423.9 4 415.8 5.3 411.8C6.5 408.2 10.7 400 15.8 391.2C18.2 387.1 24.6 375.9 30.1 366.2C35.6 356.6 41.4 346.6 42.9 344C44.4 341.4 46.6 337.6 47.8 335.5C50.1 331.2 54.1 324.4 56.4 320.8C58.8 316.7 65.2 305.5 67 302.2C67.9 300.6 68.9 298.9 69.2 298.5C69.5 298.1 71.2 295.4 72.8 292.5C74.5 289.6 77.8 284 80.1 280C82.5 276 85.3 271 86.5 268.8L88.7 264.9L87.5 263.8C86.8 263.1 78.4 258.6 68.8 253.8C59.1 248.9 51 244.6 50.6 244.1C48.9 241.8 50 241.1 61.4 237.3C66.8 235.6 75.2 232.8 80 231.1C84.8 229.4 98.5 224.9 110.5 221C122.5 217.1 135.1 212.9 138.5 211.8C149.8 207.9 195.2 192.9 198.2 192C199.9 191.5 204.9 189.8 209.3 188.3C213.8 186.8 217.7 185.5 218.1 185.5C219.5 185.5 220.4 187.3 225.4 200.8C228.2 208.2 230.8 214.7 231 215.2C231.2 215.8 232.5 218.9 233.8 222.2C235 225.6 236.7 229.8 237.4 231.8C238.2 233.7 240.9 240.7 243.5 247.2C246.1 253.8 248.4 259.9 248.8 260.8C249.2 261.6 250.2 264.4 251.2 267C252.2 269.6 254 274.2 255.2 277.2C257.6 282.9 258.8 285.8 261.8 293.8C262.7 296.2 264.4 300.4 265.4 303.2C266.6 305.9 268.1 309.9 268.9 312.2C269.8 314.4 271.1 317.8 272 319.8C273.4 322.9 274.7 326.1 279.8 339.4C280.4 341.1 280.9 342.8 280.7 343.2C279.8 345.6 278.1 344.9 249.3 330.1C238.2 324.4 235.2 323.1 234.7 323.6C233.5 324.6 223.5 341.4 215.3 356.2C214 358.8 212.2 361.9 211.3 363.2C209.6 366.2 207.2 370.4 194.8 392.2C184.6 410.1 183.3 412.4 178.3 420.9C176.5 424 175 426.6 175 426.8C175 426.9 174 428.6 172.8 430.6C171.7 432.6 169.8 435.8 168.7 437.8C166.7 441.2 165.8 442.6 161.8 450C160.6 452.1 158.8 455 157.9 456.5C156.1 459.4 149.5 470.9 149.5 471.2C149.5 471.3 147.7 474.4 145.4 478.1C141.4 484.6 133.3 498.8 132.9 499.8C132.8 500 130.8 503.6 128.3 507.8C122.2 518.1 114.2 531.7 109.8 539.2C108.8 541.1 107 544.1 106 545.8C103 550.5 96.8 561.5 95.4 564.2C93.6 567.8 90.2 577.6 89.4 581.5C89 583.6 88.8 588.5 88.8 595.6C88.8 601.6 88.8 606.5 88.7 606.5C88.6 606.5 88.2 606 87.8 605.4ZM282.1 227.9C281.9 227.6 277.1 218.4 271.8 207.8C266.3 197.1 260.9 186.4 259.8 184.2C258.6 182.1 254.1 173.3 249.8 164.8C245.4 156.2 241.6 148.9 241.2 148.6C240.7 147.9 238.8 147.9 228.7 148.7C222.1 149.2 212.2 149.8 206.5 150.2C200.8 150.7 189.9 151.4 182.2 152.1C155.8 154.1 157.5 154 157.5 152.6C157.5 152.2 159.2 148.8 161.4 145C163.6 141.3 166.3 136.4 167.6 134.2C168.7 132.1 170.4 129.1 171.2 127.8C172.2 126.4 173.8 123.3 175.1 121C176.3 118.7 180.7 111 184.8 104C188.8 97 193 89.8 194 88C195 86.2 197.3 82.2 199.2 79C203.3 72.2 207 65.8 209.8 60.9C210.9 58.9 212.4 56.2 213.1 55C217.9 46.5 220.6 41.8 222.2 38.8C225.8 32.2 227.9 28.7 230.2 25.7C234.9 19.4 245.8 11.6 252.4 9.6C267.9 5 284.1 9.9 296 22.9C299.4 26.6 305.2 35.1 308.3 40.8C309.4 42.8 312.6 48.2 315.4 52.8C320.5 61.2 323.8 66.5 330.9 78.5C332.9 82 336.1 87 337.8 89.8C342.9 98 349.6 109.6 349.9 110.5C350 111 349.1 113 348.1 115C346.9 117 346 118.7 346 118.8C346 118.8 345.3 120.2 344.4 121.6C343.6 123 341.8 126.2 340.5 128.5C339.2 130.8 337.3 134.2 336.2 136C334 139.8 328.6 149.6 322.4 161C319.9 165.6 317.1 170.4 316.2 171.8C314.7 174.2 313.9 175.6 309.8 183.2C307.9 186.8 295.2 209.1 291.4 215.8C290.2 217.7 288.4 221.1 287.1 223.2C285.1 226.9 283.9 228.5 282.9 228.5C282.8 228.5 282.4 228.2 282.1 227.9Z';

  /// The ruled strips.
  static const _ruled =
      'M457.6 697.1C456.6 695.8 454.8 693.3 453.5 691.6C452.2 689.9 450.1 687.1 448.9 685.5C447.5 683.9 444.6 680 442.2 676.9C436.4 669 428.1 657.9 425.8 654.7C424.6 653.2 422.1 649.9 420.2 647.4C409.5 633.5 396 615.1 396 614.5C396 613.6 414.7 613.5 523.9 613.5C650.7 613.5 639.9 613.2 637.4 616.9C636.7 617.9 635.4 620 634.5 621.5C631 627.5 623.1 634.6 616.5 638C612.1 640.2 605.2 642.5 601.9 642.8C600.1 642.9 568.4 643.1 531.1 643.1C486.6 643.2 463.4 643.4 463.1 643.8C462.8 644 462.5 653.9 462.4 671C462.4 685.7 462.1 698.1 461.9 698.6C461.1 700.1 459.6 699.6 457.6 697.1ZM391.3 608.9C388.6 605.6 382.2 597.2 381 595.5C380.4 594.5 378.4 592 376.8 590C372.6 584.9 370 581.2 370 580.5C370 580.1 408.6 580 514.8 580C623 580 659.5 580.1 659.5 580.5C659.5 581.2 655.8 587.5 651.9 593.5C650.4 595.6 647.5 600.4 645.4 604L641.4 610.5L517 610.5L392.6 610.5L391.3 608.9ZM362.4 571.1C360.2 568.1 357.7 564.8 356.8 563.6C355.8 562.4 355 561 355 560.4C355 559.5 357.6 556.4 367.3 545C368.1 544.1 369.9 542.1 371.3 540.5C372.7 539 374.9 536.4 376.2 534.8C377.6 533.1 380.4 529.9 382.4 527.5C384.6 525.1 388.2 521 390.6 518.2C392.9 515.5 395.2 513 395.7 512.5C396.4 511.9 416.4 511.9 528.1 512.1C666.1 512.4 666.4 512.4 675 510.2C685 507.8 696.6 503.1 704.5 498.4C705.5 497.8 708.3 495.7 710.7 493.9C713.1 492 715.3 490.5 715.5 490.6C716 490.8 712.1 497.3 706.4 506.1C704.3 509.2 702.1 512.7 701.5 513.9C700.8 515 698.5 518.6 696.5 521.9C694.5 525.1 692.5 528.1 692.2 528.6C690.5 531.8 685.4 540.1 684.5 541.2L683.5 542.5L531.9 542.5L380.2 542.5L376.5 543.6C373.8 544.5 373 545 373.5 545.3C373.9 545.5 433.6 545.8 527.6 545.9C649.5 546 681 546.1 681 546.6C681 547 679.8 549.1 678.4 551.4C673.3 559.4 664.3 573.2 663.1 574.9L662 576.5L514.1 576.5L366.2 576.5L362.4 571.1ZM400.3 508.1C400 507.6 410.8 494.6 418.7 485.8C420.7 483.6 423.5 480.3 425 478.5C427.8 475.1 431.5 470.8 435.8 466C437.1 464.4 438.9 462.4 439.7 461.4C440.5 460.5 442.8 457.9 444.7 455.8C446.7 453.6 450.9 448.6 454.2 444.9C457.4 441.1 460.4 438 460.8 438C462.4 438 462.6 439.9 462.5 463.1C462.5 475.9 462.5 486.6 462.5 487.1C462.5 487.9 465.9 488 528.2 488C572.6 488 594 487.9 594.2 487.5C594.5 487.2 592.7 483.9 590.4 480.1C586 473.1 585 471.3 585 470.8C585 470.6 616.2 470.5 654.5 470.5C697.2 470.5 724 470.7 724 470.9C724 471.9 718.2 478.7 714.5 482.2C707.1 489.2 702.9 492.2 693.8 496.6C683.6 501.4 677.5 503.1 664.9 505.1C659 505.9 655.4 506 632.6 506L607 506L606.5 507.2L606 508.5L503.3 508.5C442.1 508.5 400.4 508.3 400.3 508.1ZM579 460.9C577.1 457.5 574.5 453.2 573.2 451.2C572 449.3 570.9 447.4 570.6 447.1C570.5 446.7 569.2 444.4 567.9 442.1C566.5 439.8 565.5 437.6 565.7 437.2C565.9 436.6 580 436.6 649.6 436.6L733.2 436.8L733.5 439.8C733.8 446.4 731.5 457.3 728.1 464L726.8 466.8L654.6 466.9L582.6 467L579 460.9ZM566.4 433.1L562.5 432.9L561.2 430.9C545.6 404.9 544.9 403.6 545.2 402.9C545.5 402.7 580 402.5 634.5 402.5L723.5 402.5L724.5 404.1C727.9 409.6 731.6 419.8 732.5 426C732.8 428.4 733.1 430.8 733.2 431.4C733.3 432.1 733.1 432.7 732.7 432.9C732 433.1 573.4 433.4 566.4 433.1ZM543.9 399.1C542.2 398.9 542 398.6 538.5 392.6C537 389.9 533.2 383.6 530.3 378.6C527.4 373.6 525.1 369.2 525.2 369C525.5 368.6 556.1 368.5 614.5 368.5C698.8 368.5 703.5 368.6 704 369.4C704.3 369.9 705.6 372.1 707 374.5C713 384.4 721 398.6 720.9 398.8C720.6 399.1 546.1 399.4 543.9 399.1ZM521.9 364.1C521.5 363.6 519.9 360.9 518.2 358C516.6 355.1 514.7 351.9 514 350.8C513.2 349.6 510.1 344.5 507 339.2C503.9 334 501 329.2 500.5 328.5C498.9 326.1 498.1 324.2 498.4 323.6C498.8 323.1 509.8 324.6 532.2 328.2C536.4 328.9 544.4 330.1 550 331.1C557.5 332.2 560.5 332.9 561.3 333.6C562.2 334.4 565.1 334.5 622.8 334.5C656 334.5 683.5 334.7 683.8 334.9C684.1 335.1 686.3 338.6 688.8 342.8C691.1 346.9 693.8 351.4 694.6 352.8C697.5 357.4 701 363.9 701 364.4C701 364.9 674.6 365 611.9 365C527.5 365 522.6 364.9 521.9 364.1ZM562.8 331.4C562.6 331 563.3 329.2 564.3 327.4C565.4 325.7 567.8 321.3 569.8 317.8C571.7 314.2 574.3 309.6 575.5 307.5C576.8 305.4 578 303.1 578.5 302.2L579.2 300.8L621.8 300.6C661.8 300.5 664.3 300.6 664.8 301.4C665.1 301.9 666.1 303.6 667 305.2C670.4 311.4 676.1 321.3 677.5 323.2C679.7 326.4 681.5 330.2 681.1 330.6C680.9 330.8 656.8 331.1 627.5 331.2C598.2 331.4 571.7 331.6 568.6 331.8C564 332 563 331.9 562.8 331.4ZM582 296.4C582 296 583.9 292.6 586 288.8C588.3 284.9 590.8 280.6 591.5 279.2C592.2 277.9 593.7 275.3 594.7 273.5C595.7 271.7 596.9 269.6 597.4 268.6C597.8 267.8 598.5 266.9 598.9 266.8C599.2 266.6 609.6 266.5 621.9 266.5C642.8 266.4 644.3 266.5 644.9 267.4C645.2 267.9 646.9 270.4 648.4 273.1C652 279.4 651.9 279.1 654 282.8C655.1 284.4 656.4 286.6 656.9 287.5C657.4 288.4 658.6 290.8 659.7 292.6C660.8 294.4 661.5 296.2 661.2 296.5C660.8 297.3 582 297.2 582 296.4ZM541 281.9C529.1 279.9 501.1 275.5 497.2 275C495.1 274.7 492.4 274.2 491.5 274C490.6 273.8 486.7 273.1 483 272.5C479.3 271.9 472.8 270.9 468.5 270.2C464.2 269.6 456.2 268.3 450.8 267.5C441.4 266.1 434.1 264.9 423.2 263.2C418.5 262.4 410.9 261.2 399 259.5C395 258.9 391.4 258.1 391.1 257.9C389.8 256.8 390.5 255.7 393.4 254.1C397.4 251.8 407.9 245.3 425.6 234.3L432.4 230L503.4 230C560 230 574.5 230.2 574.5 230.6C574.5 231.3 573.4 233.7 565.5 250.2L560.1 261.2L502.7 261.6C471.1 261.8 444.5 262.1 443.6 262.2C441.7 262.7 441.6 263.2 443.2 263.7C446.9 264.6 469.5 265.1 511.6 264.9C537.1 264.9 558.1 264.9 558.2 265.1C558.4 265.2 556.6 269.4 554.2 274.2C549.2 284.4 550.6 283.6 541 281.9ZM601.6 262.7C601.1 261.3 602.8 258.9 607.1 255.1C609.4 253 613.8 249.1 616.8 246.2C625.4 238.2 625.9 237.8 627.1 238.2C628.4 238.5 629.4 240 637 253.4C639.8 258.2 642 262.4 641.9 262.6C641.8 262.9 635 263.2 621.9 263.4C603.5 263.6 602 263.5 601.6 262.7ZM427.7 223.6C426.6 221.8 424.4 217.9 422.6 215C420.8 212.1 418.4 208.1 417.2 206C416.1 203.9 414.4 201.1 413.6 199.6C412.7 198.2 412 196.7 412 196.3C412 195.8 415.2 195.6 428.6 195.2C450.1 194.8 590.3 195.2 590.8 195.6C591.2 196.1 589.8 199.3 582.2 214.8C579.1 221.2 576.2 226.5 575.8 226.7C575.3 226.8 542.2 227 502.2 227L429.6 227L427.7 223.6ZM409.1 191.6C408.6 191.3 394.5 168.2 394.5 167.7C394.5 167.7 393.6 166.2 392.4 164.5C391.4 162.8 390.6 161.1 390.7 160.7C390.9 160.1 403.8 160 483.6 160C559 160 576.5 159.9 577.2 159.3C578.5 158.4 577.4 157.7 573.8 157.2C572.1 157.1 529.6 156.8 479.4 156.7L388.1 156.5L386.4 154.1C383.9 150.7 370.1 127.5 369.9 126.5C369.8 125.8 377.6 125.8 463.9 125.6L558 125.5L561.5 131.6C574.4 153.5 575 154.5 575.6 154.5C576.1 154.5 581.6 151.2 594.2 143.2C597.9 141 602.6 138 605 136.7C607.4 135.2 611.5 132.8 614.2 131.1C619.5 127.8 621.2 127.3 621.8 129C622.1 130.3 621.9 131.3 619.2 136.8C616.1 143.3 607.2 162.3 605.9 165.5C604.6 168.1 595.2 187.8 593.9 190.5L593.2 191.8L501.4 191.8C451 191.9 409.4 191.8 409.1 191.6ZM366.6 121.4C366.4 121 365.4 119.4 364.4 117.8C363.4 116.1 360.4 111.2 357.7 106.8C355 102.3 352.3 97.8 351.8 96.7C351.1 95.5 350.3 94.2 349.9 93.5C348 90.8 343 91 443.4 91C494.8 91 537 91.2 537.3 91.4C537.6 91.6 538.8 93.5 540 95.5C541.2 97.5 542.5 99.6 542.8 100C543.1 100.4 544 102 544.9 103.5C545.6 105 548.4 109.7 550.9 113.8C553.5 118 555.5 121.5 555.5 121.7C555.5 121.9 513.1 122 461.3 122C386.6 122 367 121.8 366.6 121.4ZM344.9 85.3C336.6 72 328.5 58.4 328.5 57.6C328.5 57.4 331.8 57 337.1 56.8C348.9 56.4 516.1 56.5 516.8 56.9C517.1 57.1 518.5 59.2 520 61.8C521.4 64.2 524.1 68.8 526 72C531.5 81.1 534.5 86.5 534.5 87C534.5 87.3 503.9 87.5 440.4 87.5L346.2 87.5L344.9 85.3ZM324.6 51.6C324.1 50.9 321.1 46.1 318 41C314.9 35.9 311.1 29.9 309.4 27.6C307.9 25.2 306.6 23.2 306.7 23.1C306.9 23 449.3 22.9 489.1 23L496.9 23L500.9 29.6C504.6 35.8 507.1 39.9 512 48.6C513.1 50.5 514 52.2 514 52.5C514 52.9 484.1 53 419.8 53L325.6 53L324.6 51.6ZM300.6 16.9C299.1 15.4 297.4 13.9 297 13.6C294.4 11.2 288.7 7.4 285.5 6C279 3.3 278.4 3 278.8 2.6C279.3 2 463.2 2.5 466.9 3C470.6 3.6 476.9 6 481.5 8.6C484.9 10.6 492.5 17.1 492.5 18.2C492.5 18.6 491.5 19 489.9 19.2C488.4 19.4 445.9 19.5 395.3 19.5L303.4 19.5L300.6 16.9Z';

  static String _hex(Color c) =>
      '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  /// Only the solid arrows (for animating the parts separately).
  static String arrows(Color color) =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 735.5 701.5">'
      '<path fill="${_hex(color)}" fill-rule="evenodd" d="$_solid"/></svg>';

  /// Only the ruled strips (for animating the parts separately).
  static String strips(Color color) =>
      '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 735.5 701.5">'
      '<path fill="${_hex(color)}" fill-rule="evenodd" d="$_ruled"/></svg>';

  /// Full mark. [arc] colours the ruled strips, [head] the solid arrows;
  /// both default to the logo's forest green.
  static String mark({Color arc = AppColors.forest, Color head = AppColors.forest}) {
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 735.5 701.5">'
        '<path fill="${_hex(head)}" fill-rule="evenodd" d="$_solid"/>'
        '<path fill="${_hex(arc)}" fill-rule="evenodd" d="$_ruled"/>'
        '</svg>';
  }
}

class BrandMark extends StatelessWidget {
  final double size;
  final Color arc;
  final Color head;
  const BrandMark({
    super.key,
    this.size = 40,
    this.arc = AppColors.forest,
    this.head = AppColors.forest,
  });

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(
      BrandLogo.mark(arc: arc, head: head),
      width: size,
      height: size * BrandLogo.height / BrandLogo.width,
      semanticsLabel: 'Camacho Recycling',
    );
  }
}

/// The ruled log-sheet lines from the logo, as a quiet background pattern
/// for hero cards and panels. Purely decorative.
class RuledLines extends StatelessWidget {
  final Color color;
  final double spacing;
  final double thickness;

  /// Fade the lines out towards this side (null = no fade).
  final AlignmentGeometry? fadeTo;

  const RuledLines({
    super.key,
    this.color = const Color(0x1AFFFFFF),
    this.spacing = 16,
    this.thickness = 2,
    this.fadeTo = Alignment.centerLeft,
  });

  @override
  Widget build(BuildContext context) {
    Widget lines = CustomPaint(
      painter: _RuledLinesPainter(color: color, spacing: spacing, thickness: thickness),
      size: Size.infinite,
    );
    final fade = fadeTo?.resolve(Directionality.maybeOf(context) ?? TextDirection.ltr);
    if (fade != null) {
      lines = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) => LinearGradient(
          begin: fade,
          end: -fade,
          colors: const [Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
        child: lines,
      );
    }
    return IgnorePointer(child: ExcludeSemantics(child: lines));
  }
}

class _RuledLinesPainter extends CustomPainter {
  final Color color;
  final double spacing;
  final double thickness;
  const _RuledLinesPainter({required this.color, required this.spacing, required this.thickness});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness;
    for (double y = spacing / 2; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_RuledLinesPainter old) =>
      old.color != color || old.spacing != spacing || old.thickness != thickness;
}

/// The mark drawing itself once, like the launch splash: the arrows settle
/// in, then the ruled strips fill in top to bottom like lines being written.
/// Plays when shown; still (fully drawn) under "Reduce motion".
class DrawnBrandMark extends StatefulWidget {
  final double size;
  final Color arrows;
  final Color strips;
  final Duration duration;
  final Duration delay;
  const DrawnBrandMark({
    super.key,
    required this.size,
    this.arrows = AppColors.forest,
    this.strips = AppColors.olive,
    this.duration = const Duration(milliseconds: 1400),
    this.delay = Duration.zero,
  });

  @override
  State<DrawnBrandMark> createState() => _DrawnBrandMarkState();
}

class _DrawnBrandMarkState extends State<DrawnBrandMark> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.duration);
  bool _started = false;
  Timer? _delay;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
    } else if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      _delay = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _c.dispose();
    super.dispose();
  }

  double _seg(double begin, double end, [Curve curve = Curves.easeOutCubic]) =>
      curve.transform(((_c.value - begin) / (end - begin)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final w = widget.size;
    final h = w * BrandLogo.height / BrandLogo.width;
    final arrowsSvg = SvgPicture.string(BrandLogo.arrows(widget.arrows), width: w, height: h);
    final stripsSvg = SvgPicture.string(BrandLogo.strips(widget.strips), width: w, height: h);
    return SizedBox(
      width: w,
      height: h,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final a = _seg(0.0, 0.45);
          final t = _seg(0.3, 1.0, Curves.easeInOutCubic);
          return Stack(
            children: [
              Opacity(
                opacity: a,
                child: Transform.rotate(
                  angle: (1 - a) * -0.24,
                  child: Transform.scale(scale: 0.86 + 0.14 * a, child: arrowsSvg),
                ),
              ),
              ClipRect(clipper: _TopRevealClip(t), child: stripsSvg),
            ],
          );
        },
      ),
    );
  }
}

class _TopRevealClip extends CustomClipper<Rect> {
  final double t;
  const _TopRevealClip(this.t);

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width, size.height * t);

  @override
  bool shouldReclip(covariant _TopRevealClip old) => old.t != t;
}

/// Slowly rotating copy of the mark, used as background art.
class SpinningBrandMark extends StatefulWidget {
  final double size;
  final Color arc;
  final Color head;
  final Duration period;

  /// Spin counter-clockwise instead of clockwise.
  final bool reverse;
  const SpinningBrandMark({
    super.key,
    required this.size,
    this.arc = AppColors.olive,
    this.head = AppColors.sage,
    this.period = const Duration(seconds: 40),
    this.reverse = false,
  });

  @override
  State<SpinningBrandMark> createState() => _SpinningBrandMarkState();
}

class _SpinningBrandMarkState extends State<SpinningBrandMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: widget.period);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.of(context).disableAnimations) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: RotationTransition(
        turns: widget.reverse
            ? Tween<double>(begin: 0, end: -1).animate(_c)
            : _c,
        child: BrandMark(size: widget.size, arc: widget.arc, head: widget.head),
      ),
    );
  }
}

/// Fade + small rise on first build, with an optional delay for staggering.
/// Skipped when iOS "Reduce Motion" is on.
class Entrance extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final double dy;
  const Entrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.dy = 12,
  });

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 300),
  );
  late final Animation<double> _t =
      CurvedAnimation(parent: _c, curve: Curves.easeOutCubic);
  Timer? _timer;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.of(context).disableAnimations) {
      _c.value = 1;
    } else if (widget.delay == Duration.zero) {
      _c.forward();
    } else {
      _timer = Timer(widget.delay, () {
        if (mounted) _c.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _t,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(0, widget.dy * (1 - _t.value)),
          child: child,
        ),
      ),
    );
  }
}

/// Scales its child to 0.98 while pressed.
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius borderRadius;
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _down ? 0.98 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: Material(
        color: Colors.transparent,
        borderRadius: widget.borderRadius,
        child: InkWell(
          borderRadius: widget.borderRadius,
          onTap: widget.onTap,
          onHighlightChanged: (v) => setState(() => _down = v),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Plain-language, coloured snackbar used across the redesigned screens.
void showAppSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? AppColors.redText : AppColors.navy,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Row(
          children: [
            Icon(
              error ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}

/// Turns raw exceptions into short sentences for staff.
String friendlyError(Object e) {
  final s = e.toString();
  if (s.contains('permission-denied')) {
    return "You don't have permission to do that. Ask an admin.";
  }
  if (s.contains('unavailable') || s.contains('network')) {
    return 'No connection. Check the Wi-Fi and try again.';
  }
  return s.replaceFirst('Exception: ', '');
}
